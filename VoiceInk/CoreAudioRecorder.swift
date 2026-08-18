import AVFoundation
import Atomics
import AudioToolbox
import CoreAudio
import Foundation
import os

struct AudioInputChannelSelection: Equatable {
    let deviceChannelIndices: [Int32]

    static func resolve(
        deviceChannelCount: UInt32,
        preferredStereoChannels: [UInt32]?
    ) -> AudioInputChannelSelection {
        guard deviceChannelCount > 0 else {
            return AudioInputChannelSelection(deviceChannelIndices: [])
        }

        let fallback = (0..<min(deviceChannelCount, 2)).map(Int32.init)
        guard let preferredStereoChannels,
              !preferredStereoChannels.isEmpty,
              preferredStereoChannels.allSatisfy({ (1...deviceChannelCount).contains($0) }) else {
            return AudioInputChannelSelection(deviceChannelIndices: fallback)
        }

        var seen = Set<UInt32>()
        let preferred = preferredStereoChannels.compactMap { channel -> Int32? in
            guard seen.insert(channel).inserted else { return nil }
            return Int32(channel - 1)
        }

        return AudioInputChannelSelection(deviceChannelIndices: preferred)
    }
}

enum AudioCaptureBufferingPolicy {
    /// Keeps roughly several seconds of hardware input available during short
    /// CPU bursts. The ring stores preallocated Float32 buffers, so increasing
    /// it does not allocate from the realtime render callback.
    static let inputRingSlotCount = 256
}

enum AudioFileWriteBatchingPolicy {
    static let sampleRate = 16_000
    static let bytesPerFrame = MemoryLayout<Int16>.size
    static let batchDurationMilliseconds = 250
    static let targetBatchByteCount =
        sampleRate * bytesPerFrame * batchDurationMilliseconds / 1_000
}

struct AudioFileWriteBatcher {
    let targetBatchByteCount: Int
    private(set) var bufferedData = Data()

    init(targetBatchByteCount: Int = AudioFileWriteBatchingPolicy.targetBatchByteCount) {
        precondition(targetBatchByteCount > 0)
        self.targetBatchByteCount = targetBatchByteCount
        bufferedData.reserveCapacity(targetBatchByteCount)
    }

    var bufferedByteCount: Int { bufferedData.count }

    mutating func append(_ data: Data) -> Data? {
        bufferedData.append(data)
        guard bufferedData.count >= targetBatchByteCount else { return nil }
        return takeBufferedData()
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer) -> Data? {
        bufferedData.append(contentsOf: bytes)
        guard bufferedData.count >= targetBatchByteCount else { return nil }
        return takeBufferedData()
    }

    mutating func flush() -> Data? {
        guard !bufferedData.isEmpty else { return nil }
        return takeBufferedData()
    }

    mutating func reset() {
        bufferedData.removeAll(keepingCapacity: true)
    }

    private mutating func takeBufferedData() -> Data {
        let batch = bufferedData
        bufferedData = Data()
        bufferedData.reserveCapacity(targetBatchByteCount)
        return batch
    }
}

// MARK: - Core Audio Recorder (AUHAL-based, does not change system default device)
final class CoreAudioRecorder: @unchecked Sendable {
    private final class InputBufferSlot: @unchecked Sendable {
        let samples: UnsafeMutablePointer<Float32>
        let capacitySamples: UInt32
        var frameCount: UInt32 = 0
        var channelCount: UInt32 = 0
        var sampleRate: Double = 0

        init(capacitySamples: UInt32) {
            self.capacitySamples = capacitySamples
            self.samples = UnsafeMutablePointer<Float32>.allocate(capacity: Int(capacitySamples))
        }

        deinit {
            samples.deallocate()
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CoreAudioRecorder")

    private var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?

    private var isRecording = false
    private var isAudioUnitInitialized = false
    private var currentDeviceID: AudioDeviceID = 0
    private var recordingURL: URL?

    // Device format (what the hardware provides)
    private var deviceFormat = AudioStreamBasicDescription()
    private var captureChannelCount: UInt32 = 1
    // Output format (16kHz mono PCM Int16 for transcription)
    private var outputFormat = AudioStreamBasicDescription()

    // Recording-lifetime converter, accessed only on audioProcessingQueue.
    private var audioResampler: StatefulAudioResampler?

    // Audio metering. Store bit patterns so the render callback never locks.
    private let averagePowerBits = ManagedAtomic<UInt32>(Float32(-160.0).bitPattern)
    private let peakPowerBits = ManagedAtomic<UInt32>(Float32(-160.0).bitPattern)

    var averagePower: Float {
        Float32(bitPattern: averagePowerBits.load(ordering: .relaxed))
    }

    var peakPower: Float {
        Float32(bitPattern: peakPowerBits.load(ordering: .relaxed))
    }

    // Pre-allocated render buffer (to avoid malloc in real-time callback)
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferSize: UInt32 = 0

    // Keep the render callback realtime-safe; processing is best-effort under sustained overload.
    private let audioProcessingQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.audioProcessing", qos: .userInteractive)
    private let audioProcessingQueueKey = DispatchSpecificKey<Void>()
    private let audioFileWriteQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.audioFileWrite", qos: .utility)
    private let maxFramesPerRender: UInt32 = 4096
    private let inputRingSlotCount = AudioCaptureBufferingPolicy.inputRingSlotCount
    private var inputBufferSlots: [InputBufferSlot] = []
    private var inputBufferCapacitySamples: UInt32 = 0
    private let inputWriteIndex = ManagedAtomic<UInt64>(0)
    private let inputReadIndex = ManagedAtomic<UInt64>(0)
    private let audioProcessingScheduled = ManagedAtomic(false)
    private let recordingActive = ManagedAtomic(false)
    private let renderCallbacksInFlight = ManagedAtomic<UInt32>(0)
    private let droppedInputBuffersBackpressure = ManagedAtomic<UInt64>(0)
    private let droppedInputBuffersCapacity = ManagedAtomic<UInt64>(0)
    private let droppedInputFrames = ManagedAtomic<UInt64>(0)
    private let capturedInputFrames = ManagedAtomic<UInt64>(0)
    private let convertedOutputFrames = ManagedAtomic<UInt64>(0)
    private let capturedInputSampleRateBits = ManagedAtomic<UInt64>(Double(0).bitPattern)
    private(set) var lastCaptureIntegritySnapshot = AudioCaptureIntegritySnapshot.empty
    // Accessed only from audioProcessingQueue. Completed batches are handed to
    // audioFileWriteQueue so disk latency never gates realtime transcription.
    private var audioFileWriteBatcher = AudioFileWriteBatcher()

    /// Called from the recorder processing queue with raw PCM data (16-bit, 16kHz, mono) for streaming.
    private let audioChunkLock = NSLock()
    private var _onAudioChunk: ((_ data: Data) -> Void)?
    var onAudioChunk: ((_ data: Data) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onAudioChunk
        }
        set {
            audioChunkLock.lock()
            _onAudioChunk = newValue
            audioChunkLock.unlock()
        }
    }

    // MARK: - Initialization

    init() {
        audioProcessingQueue.setSpecific(key: audioProcessingQueueKey, value: ())
    }

    deinit {
        teardown()
    }

    // MARK: - Public Interface

    /// Prepares AUHAL for the selected device without starting capture.
    func prepare(deviceID: AudioDeviceID) throws {
        if isRecording {
            return
        }

        try validateDevice(deviceID)

        if isPrepared(for: deviceID) {
            return
        }

        teardownPreparedAudioUnit()
        currentDeviceID = deviceID

        logDeviceDetails(deviceID: deviceID)

        do {
            try createAudioUnit()

            try setInputDevice(deviceID)

            try configureFormats()

            try setupInputCallback()

            try initializeAudioUnit()
        } catch {
            teardownPreparedAudioUnit()
            throw error
        }
    }

    /// Starts recording from the specified device to the given URL (WAV format)
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        // Stop any existing recording
        stopRecording()

        try prepare(deviceID: deviceID)

        do {
            recordingURL = url

            // The output file is per recording; the AUHAL setup above is reused.
            try createOutputFile(at: url)
            resetAudioProcessingState()
            resetAudioFileWriteBuffer()
            resetCaptureIntegrityCounters()
            resetAudioResampler(
                inputSampleRate: deviceFormat.mSampleRate,
                maximumInputFrames: renderFrameCapacity(for: currentDeviceID)
            )

            try startAudioUnit()
        } catch {
            isRecording = false
            recordingActive.store(false, ordering: .releasing)
            closeOutputFileAfterPendingWrites()
            recordingURL = nil
            teardownPreparedAudioUnit()
            throw error
        }
    }

    /// Stops the current recording
    func stopRecording() {
        guard isRecording || audioFile != nil else {
            return
        }

        let wasRecording = isRecording
        isRecording = false
        recordingActive.store(false, ordering: .releasing)

        if wasRecording, let unit = audioUnit {
            let stopStatus = AudioOutputUnitStop(unit)
            if stopStatus != noErr {
                logger.warning("🎙️ AudioOutputUnitStop returned \(stopStatus, privacy: .public)")
            }

            waitForRenderCallbacksToFinish()

            let resetStatus = AudioUnitReset(unit, kAudioUnitScope_Global, 0)
            if resetStatus != noErr {
                logger.warning("🎙️ AudioUnitReset returned \(resetStatus, privacy: .public)")
            }
        }

        drainAudioProcessingQueue(flushResampler: true, flushAudioFileBuffer: true)
        lastCaptureIntegritySnapshot = captureIntegritySnapshot()
        logDroppedInputBufferCounters(context: "stop", snapshot: lastCaptureIntegritySnapshot)

        closeOutputFileAfterPendingWrites()
        recordingURL = nil

        resetMeters()
    }

    /// Releases the prepared AUHAL and buffers. Use for app shutdown or hard recovery.
    func teardown() {
        stopRecording()
        teardownPreparedAudioUnit()
        recordingURL = nil
        currentDeviceID = 0
        resetMeters()
    }

    var isCurrentlyRecording: Bool { isRecording }
    var currentRecordingURL: URL? { recordingURL }
    var currentDevice: AudioDeviceID { currentDeviceID }

    /// Switches to a new input device mid-recording without stopping the file write
    func switchDevice(to newDeviceID: AudioDeviceID) throws {
        guard isRecording, let unit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Don't switch if it's the same device
        guard newDeviceID != currentDeviceID else { return }

        let oldDeviceID = currentDeviceID
        logger.notice(
            "🎙️ Switching recording device from \(oldDeviceID, privacy: .public) to \(newDeviceID, privacy: .public)")

        // Step 1: Stop the AudioUnit (but keep file open)
        recordingActive.store(false, ordering: .releasing)
        var status = AudioOutputUnitStop(unit)
        if status != noErr {
            logger.warning("🎙️ Warning: AudioOutputUnitStop returned \(status, privacy: .public)")
        }

        waitForRenderCallbacksToFinish()
        drainAudioProcessingQueue(flushResampler: true)
        logDroppedInputBufferCounters(context: "device-switch", snapshot: captureIntegritySnapshot())

        // Step 2: Uninitialize to allow reconfiguration
        status = AudioUnitUninitialize(unit)
        if status != noErr {
            logger.warning("🎙️ Warning: AudioUnitUninitialize returned \(status, privacy: .public)")
        }
        isAudioUnitInitialized = false

        // Step 3: Set the new device
        var device = newDeviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            // Try to recover by restarting with old device
            logger.error("Failed to set new device: \(status, privacy: .public). Attempting recovery...")
            var recoveryDevice = oldDeviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &recoveryDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            let initializeStatus = AudioUnitInitialize(unit)
            isAudioUnitInitialized = initializeStatus == noErr
            if initializeStatus == noErr {
                let startStatus = AudioOutputUnitStart(unit)
                if startStatus == noErr {
                    recordingActive.store(true, ordering: .releasing)
                }
            }
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }

        // Step 4: Get new device format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var newDeviceFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &newDeviceFormat,
            &formatSize
        )

        if status != noErr {
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        // Step 5: Configure callback format and map only the device's preferred input channels.
        let newCaptureChannelCount = try configureCaptureFormat(
            deviceID: newDeviceID,
            deviceFormat: newDeviceFormat
        )

        // Step 6: Reallocate buffers if needed
        allocateAudioBuffers(
            maxFrames: renderFrameCapacity(for: newDeviceID),
            channelCount: newCaptureChannelCount,
            inputSampleRate: newDeviceFormat.mSampleRate,
            resetQueuedAudio: true
        )

        // Update stored format
        deviceFormat = newDeviceFormat
        captureChannelCount = newCaptureChannelCount
        currentDeviceID = newDeviceID

        // Step 7: Reinitialize and restart
        status = AudioUnitInitialize(unit)
        if status != noErr {
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }
        isAudioUnitInitialized = true

        status = AudioOutputUnitStart(unit)
        if status != noErr {
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
        recordingActive.store(true, ordering: .releasing)

        logger.notice("🎙️ Successfully switched to device \(newDeviceID, privacy: .public)")
    }

    // MARK: - AudioUnit Setup

    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioUnit not found - HAL Output component unavailable")
            throw CoreAudioRecorderError.audioUnitNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            logger.error("Failed to create AudioUnit instance: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToCreateAudioUnit(status: status)
        }

        self.audioUnit = audioUnit

        // Enable input on element 1 (input scope)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,  // Element 1 = input
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to enable audio input: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToEnableInput(status: status)
        }

        // Disable output on element 0 (output scope)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,  // Element 0 = output
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to disable audio output: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToDisableOutput(status: status)
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            logger.error("Failed to set input device \(deviceID, privacy: .public): \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }
    }

    private func configureFormats() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Get the device's native format (input scope, element 1)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )

        if status != noErr {
            logger.error("Failed to get device format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        // Configure output format: 16kHz, mono, PCM Int16
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        captureChannelCount = try configureCaptureFormat(
            deviceID: currentDeviceID,
            deviceFormat: deviceFormat
        )

        // Log format details
        let devSampleRate = deviceFormat.mSampleRate
        let devChannels = deviceFormat.mChannelsPerFrame
        let devBits = deviceFormat.mBitsPerChannel
        let outSampleRate = outputFormat.mSampleRate
        let outChannels = outputFormat.mChannelsPerFrame
        let outBits = outputFormat.mBitsPerChannel
        logger.notice(
            "🎙️ Device format: sampleRate=\(devSampleRate, privacy: .public), channels=\(devChannels, privacy: .public), bitsPerChannel=\(devBits, privacy: .public)"
        )
        logger.notice(
            "🎙️ Output format: sampleRate=\(outSampleRate, privacy: .public), channels=\(outChannels, privacy: .public), bitsPerChannel=\(outBits, privacy: .public)"
        )
        if devSampleRate != outSampleRate {
            logger.notice(
                "🎙️ Converting: \(Int(devSampleRate), privacy: .public)Hz → \(Int(outSampleRate), privacy: .public)Hz")
        }

        freeBuffers()

        allocateAudioBuffers(
            maxFrames: renderFrameCapacity(for: currentDeviceID),
            channelCount: captureChannelCount,
            inputSampleRate: deviceFormat.mSampleRate,
            resetQueuedAudio: true
        )
    }

    private func configureCaptureFormat(
        deviceID: AudioDeviceID,
        deviceFormat: AudioStreamBasicDescription
    ) throws -> UInt32 {
        guard let audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: deviceFormat.mChannelsPerFrame,
            preferredStereoChannels: getPreferredInputChannels(deviceID: deviceID)
        )
        let channelCount = UInt32(selection.deviceChannelIndices.count)
        guard channelCount > 0 else {
            throw CoreAudioRecorderError.failedToSetFormat(status: kAudio_ParamError)
        }

        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            logger.error("Failed to set audio format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetFormat(status: status)
        }

        var channelMap = selection.deviceChannelIndices
        status = channelMap.withUnsafeMutableBytes { bytes in
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                1,
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard status == noErr else {
            logger.error("Failed to map audio input channels: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetFormat(status: status)
        }

        let mappedChannels = selection.deviceChannelIndices.map { $0 + 1 }
        logger.notice("🎙️ Capturing device input channels: \(mappedChannels, privacy: .public)")
        return channelCount
    }

    private func allocateAudioBuffers(
        maxFrames: UInt32,
        channelCount: UInt32,
        inputSampleRate: Double,
        resetQueuedAudio: Bool
    ) {
        let bufferSamples = maxFrames * channelCount

        if bufferSamples > renderBufferSize {
            renderBuffer?.deallocate()
            renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
            renderBufferSize = bufferSamples
        }

        if inputBufferCapacitySamples != bufferSamples || inputBufferSlots.count != inputRingSlotCount {
            inputBufferSlots.removeAll()
            inputBufferSlots = (0..<inputRingSlotCount).map { _ in
                InputBufferSlot(capacitySamples: bufferSamples)
            }
            inputBufferCapacitySamples = bufferSamples
        }

        resetAudioResampler(inputSampleRate: inputSampleRate, maximumInputFrames: maxFrames)

        if resetQueuedAudio {
            resetAudioProcessingState()
        }
    }

    private func setupInputCallback() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        if status != noErr {
            logger.error("Failed to set input callback: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetCallback(status: status)
        }
    }

    private func createOutputFile(at url: URL) throws {
        // Remove existing file if any
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Create ExtAudioFile for writing
        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )

        if status != noErr {
            logger.error("Failed to create audio file at \(url.path, privacy: .public): \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToCreateFile(status: status)
        }

        audioFile = fileRef

        // Set client format (what we'll write)
        status = ExtAudioFileSetProperty(
            fileRef!,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &outputFormat
        )

        if status != noErr {
            logger.error("Failed to set file format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetFileFormat(status: status)
        }
    }

    private func initializeAudioUnit() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        guard !isAudioUnitInitialized else { return }

        let status = AudioUnitInitialize(audioUnit)
        if status != noErr {
            logger.error("Failed to initialize AudioUnit: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }
        isAudioUnitInitialized = true
    }

    private func startAudioUnit() throws {
        guard let audioUnit = audioUnit, isAudioUnitInitialized else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        isRecording = true
        recordingActive.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(audioUnit)
        if status != noErr {
            isRecording = false
            recordingActive.store(false, ordering: .releasing)
            logger.error("Failed to start AudioUnit: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
    }

    private func isPrepared(for deviceID: AudioDeviceID) -> Bool {
        audioUnit != nil && isAudioUnitInitialized && currentDeviceID == deviceID && isDeviceAvailable(deviceID)
    }

    private func validateDevice(_ deviceID: AudioDeviceID) throws {
        if deviceID == 0 {
            logger.error("Cannot start recording - no valid audio device (deviceID is 0)")
            throw CoreAudioRecorderError.failedToSetDevice(status: 0)
        }

        guard isDeviceAvailable(deviceID) else {
            logger.error("Cannot start recording - device \(deviceID, privacy: .public) is no longer available")
            throw CoreAudioRecorderError.deviceNotAvailable
        }
    }

    private func closeOutputFile() {
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
    }

    private func closeOutputFileAfterPendingWrites() {
        audioFileWriteQueue.sync {
            closeOutputFile()
        }
    }

    private func teardownPreparedAudioUnit() {
        recordingActive.store(false, ordering: .releasing)
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            waitForRenderCallbacksToFinish()
            if isAudioUnitInitialized {
                AudioUnitUninitialize(unit)
            }
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        drainAudioProcessingQueue()
        logDroppedInputBufferCounters(context: "teardown")
        isAudioUnitInitialized = false
        freeBuffers()
    }

    private func freeBuffers() {
        drainAudioProcessingQueue()

        audioResampler = nil

        if let buffer = renderBuffer {
            buffer.deallocate()
            renderBuffer = nil
            renderBufferSize = 0
        }

        inputBufferSlots.removeAll()
        inputBufferCapacitySamples = 0
        resetAudioProcessingState()
    }

    private func resetMeters() {
        averagePowerBits.store(Float32(-160.0).bitPattern, ordering: .relaxed)
        peakPowerBits.store(Float32(-160.0).bitPattern, ordering: .relaxed)
    }

    // MARK: - Input Callback

    private let inputCallback: AURenderCallback = {
        (
            inRefCon,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            ioData
        ) -> OSStatus in

        let recorder = Unmanaged<CoreAudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleInputBuffer(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleInputBuffer(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {

        renderCallbacksInFlight.wrappingIncrement(ordering: .acquiringAndReleasing)
        defer {
            renderCallbacksInFlight.wrappingDecrement(ordering: .acquiringAndReleasing)
        }

        guard let audioUnit = audioUnit,
            recordingActive.load(ordering: .acquiring)
        else {
            return noErr
        }

        let channelCount = captureChannelCount
        let inputSampleRate = deviceFormat.mSampleRate
        let requiredSamples = inNumberFrames * channelCount
        capturedInputFrames.wrappingIncrement(by: UInt64(inNumberFrames), ordering: .relaxed)
        capturedInputSampleRateBits.store(inputSampleRate.bitPattern, ordering: .relaxed)

        guard let renderBuf = renderBuffer,
            requiredSamples <= renderBufferSize,
            requiredSamples <= inputBufferCapacitySamples
        else {
            droppedInputBuffersCapacity.wrappingIncrement(ordering: .relaxed)
            droppedInputFrames.wrappingIncrement(by: UInt64(inNumberFrames), ordering: .relaxed)
            return noErr
        }

        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * channelCount
        let bufferSize = inNumberFrames * bytesPerFrame

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: bufferSize,
                mData: renderBuf
            )
        )

        // Render audio from the input
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            &bufferList
        )

        if status != noErr {
            return status
        }

        // Calculate audio meters from input buffer
        calculateMeters(from: &bufferList, frameCount: inNumberFrames)

        enqueueInputBuffer(
            &bufferList,
            frameCount: inNumberFrames,
            inputSampleRate: inputSampleRate
        )

        return noErr
    }

    private func calculateMeters(from bufferList: inout AudioBufferList, frameCount: UInt32) {
        guard let data = bufferList.mBuffers.mData else { return }
        guard frameCount > 0 else { return }

        let samples = data.assumingMemoryBound(to: Float32.self)
        let channelCount = Int(bufferList.mBuffers.mNumberChannels)
        let totalSamples = Int(frameCount) * channelCount

        guard totalSamples > 0 else { return }

        var sum: Float = 0.0
        var peak: Float = 0.0

        for i in 0..<totalSamples {
            let sample = abs(samples[i])
            sum += sample * sample
            if sample > peak {
                peak = sample
            }
        }

        let rms = sqrt(sum / Float(totalSamples))
        let avgDb = 20.0 * log10(max(rms, 0.000001))
        let peakDb = 20.0 * log10(max(peak, 0.000001))

        averagePowerBits.store(avgDb.bitPattern, ordering: .relaxed)
        peakPowerBits.store(peakDb.bitPattern, ordering: .relaxed)
    }

    private func enqueueInputBuffer(
        _ inputBuffer: inout AudioBufferList,
        frameCount: UInt32,
        inputSampleRate: Double
    ) {
        guard !inputBufferSlots.isEmpty,
            let inputData = inputBuffer.mBuffers.mData
        else {
            return
        }

        let channelCount = inputBuffer.mBuffers.mNumberChannels
        let sampleCount = frameCount * channelCount

        guard sampleCount <= inputBufferCapacitySamples else {
            droppedInputBuffersCapacity.wrappingIncrement(ordering: .relaxed)
            droppedInputFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
            return
        }

        let writeIndex = inputWriteIndex.load(ordering: .relaxed)
        let readIndex = inputReadIndex.load(ordering: .acquiring)
        guard writeIndex - readIndex < UInt64(inputBufferSlots.count) else {
            droppedInputBuffersBackpressure.wrappingIncrement(ordering: .relaxed)
            droppedInputFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
            return
        }

        let slot = inputBufferSlots[Int(writeIndex % UInt64(inputBufferSlots.count))]
        slot.frameCount = frameCount
        slot.channelCount = channelCount
        slot.sampleRate = inputSampleRate

        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)
        slot.samples.update(from: inputSamples, count: Int(sampleCount))

        inputWriteIndex.store(writeIndex + 1, ordering: .releasing)
        scheduleAudioProcessing()
    }

    private func scheduleAudioProcessing() {
        let wasScheduled = audioProcessingScheduled.exchange(true, ordering: .acquiringAndReleasing)
        guard !wasScheduled else { return }

        audioProcessingQueue.async { [weak self] in
            self?.processQueuedInputBuffers()
        }
    }

    private func processQueuedInputBuffers(maxBuffers: Int? = nil) {
        var processedBuffers = 0

        while maxBuffers.map({ processedBuffers < $0 }) ?? true {
            let readIndex = inputReadIndex.load(ordering: .relaxed)
            let writeIndex = inputWriteIndex.load(ordering: .acquiring)

            guard readIndex < writeIndex, !inputBufferSlots.isEmpty else {
                audioProcessingScheduled.store(false, ordering: .releasing)

                let latestReadIndex = inputReadIndex.load(ordering: .acquiring)
                let latestWriteIndex = inputWriteIndex.load(ordering: .acquiring)
                if latestReadIndex < latestWriteIndex {
                    scheduleAudioProcessing()
                }
                return
            }

            let slot = inputBufferSlots[Int(readIndex % UInt64(inputBufferSlots.count))]
            convertAndDispatchAudio(
                inputSamples: slot.samples,
                frameCount: slot.frameCount,
                inputChannels: slot.channelCount,
                inputSampleRate: slot.sampleRate
            )
            inputReadIndex.store(readIndex + 1, ordering: .releasing)
            processedBuffers += 1
        }

        if maxBuffers != nil,
            inputReadIndex.load(ordering: .acquiring) < inputWriteIndex.load(ordering: .acquiring)
        {
            scheduleAudioProcessing()
        }
    }

    private func drainAudioProcessingQueue(
        flushResampler: Bool = false,
        flushAudioFileBuffer: Bool = false
    ) {
        let drain = {
            self.processQueuedInputBuffers()
            if flushResampler {
                self.flushAudioResampler()
            }
            if flushAudioFileBuffer {
                self.flushAudioFileWriteBuffer()
            }
        }

        if DispatchQueue.getSpecific(key: audioProcessingQueueKey) != nil {
            drain()
        } else {
            audioProcessingQueue.sync(execute: drain)
        }
    }

    private func waitForRenderCallbacksToFinish() {
        while renderCallbacksInFlight.load(ordering: .acquiring) > 0 {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func logDroppedInputBufferCounters(
        context: String,
        snapshot: AudioCaptureIntegritySnapshot? = nil
    ) {
        let snapshot = snapshot ?? captureIntegritySnapshot()
        if snapshot.hasCaptureLoss {
            logger.warning(
                "🎙️ Dropped input buffers context=\(context, privacy: .public) backpressure=\(snapshot.droppedBackpressureBuffers, privacy: .public) capacity=\(snapshot.droppedCapacityBuffers, privacy: .public) frames=\(snapshot.droppedFrames, privacy: .public)"
            )
        }
    }

    private func captureIntegritySnapshot() -> AudioCaptureIntegritySnapshot {
        AudioCaptureIntegritySnapshot(
            droppedBackpressureBuffers: droppedInputBuffersBackpressure.load(ordering: .acquiring),
            droppedCapacityBuffers: droppedInputBuffersCapacity.load(ordering: .acquiring),
            droppedFrames: droppedInputFrames.load(ordering: .acquiring),
            inputFrames: capturedInputFrames.load(ordering: .acquiring),
            outputFrames: convertedOutputFrames.load(ordering: .acquiring),
            inputSampleRate: Double(bitPattern: capturedInputSampleRateBits.load(ordering: .acquiring))
        )
    }

    private func resetCaptureIntegrityCounters() {
        droppedInputBuffersBackpressure.store(0, ordering: .releasing)
        droppedInputBuffersCapacity.store(0, ordering: .releasing)
        droppedInputFrames.store(0, ordering: .releasing)
        capturedInputFrames.store(0, ordering: .releasing)
        convertedOutputFrames.store(0, ordering: .releasing)
        capturedInputSampleRateBits.store(Double(0).bitPattern, ordering: .releasing)
        lastCaptureIntegritySnapshot = .empty
    }

    private func resetAudioProcessingState() {
        inputWriteIndex.store(0, ordering: .relaxed)
        inputReadIndex.store(0, ordering: .relaxed)
        audioProcessingScheduled.store(false, ordering: .relaxed)
    }

    private func resetAudioFileWriteBuffer() {
        audioProcessingQueue.sync {
            audioFileWriteBatcher.reset()
        }
    }

    private func resetAudioResampler(inputSampleRate: Double, maximumInputFrames: UInt32) {
        let reset = {
            self.audioResampler = try? StatefulAudioResampler(
                inputSampleRate: inputSampleRate,
                outputSampleRate: self.outputFormat.mSampleRate,
                maximumInputFrames: maximumInputFrames
            )
        }
        if DispatchQueue.getSpecific(key: audioProcessingQueueKey) != nil {
            reset()
        } else {
            audioProcessingQueue.sync(execute: reset)
        }
    }

    private func convertAndDispatchAudio(
        inputSamples: UnsafeMutablePointer<Float32>,
        frameCount: UInt32,
        inputChannels: UInt32,
        inputSampleRate: Double
    ) {
        guard let audioResampler,
            abs(audioResampler.inputSampleRate - inputSampleRate) < 0.5
        else {
            logger.error("🎙️ Audio resampler is unavailable for \(inputSampleRate, privacy: .public) Hz input")
            return
        }

        do {
            let data = try audioResampler.convert(
                interleavedSamples: UnsafePointer(inputSamples),
                frameCount: frameCount,
                channelCount: inputChannels
            )
            dispatchConvertedAudio(data)
        } catch {
            logger.error("🎙️ Audio conversion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func flushAudioResampler() {
        guard let audioResampler else { return }
        do {
            dispatchConvertedAudio(try audioResampler.finish())
        } catch {
            logger.error("🎙️ Failed to flush audio converter: \(error.localizedDescription, privacy: .public)")
        }
        self.audioResampler = nil
    }

    private func dispatchConvertedAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        convertedOutputFrames.wrappingIncrement(
            by: UInt64(data.count / MemoryLayout<Int16>.size),
            ordering: .relaxed
        )
        onAudioChunk?(data)
        if let batch = audioFileWriteBatcher.append(data) {
            enqueueAudioFileWrite(batch)
        }
    }

    private func flushAudioFileWriteBuffer() {
        if let batch = audioFileWriteBatcher.flush() {
            enqueueAudioFileWrite(batch)
        }
    }

    private func enqueueAudioFileWrite(_ data: Data) {
        audioFileWriteQueue.async { [self] in
            writeAudioFileBatch(data)
        }
    }

    private func writeAudioFileBatch(_ data: Data) {
        guard let file = audioFile, !data.isEmpty else { return }
        let bytesPerFrame = MemoryLayout<Int16>.size
        guard data.count.isMultiple(of: bytesPerFrame) else {
            logger.error("🎙️ Refusing misaligned PCM batch bytes=\(data.count, privacy: .public)")
            return
        }

        let frameCount = UInt32(data.count / bytesPerFrame)
        let writeStatus = data.withUnsafeBytes { bytes -> OSStatus in
            var outputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(data.count),
                    mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)
                )
            )
            return ExtAudioFileWrite(file, frameCount, &outputBufferList)
        }
        if writeStatus != noErr {
            logger.error("🎙️ ExtAudioFileWrite failed with status: \(writeStatus, privacy: .public)")
        }
    }

    private func renderFrameCapacity(for deviceID: AudioDeviceID) -> UInt32 {
        max(maxFramesPerRender, getBufferFrameSize(deviceID: deviceID) ?? maxFramesPerRender)
    }

    // MARK: - Device Info Logging

    private func logDeviceDetails(deviceID: AudioDeviceID) {
        // Get device name
        let deviceName =
            getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"

        // Get device UID
        let deviceUID =
            getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown"

        // Get transport type
        let transportType = getTransportType(deviceID: deviceID)

        // Get manufacturer
        let manufacturer =
            getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString)
            ?? "Unknown"

        logger.notice("🎙️ Device info: name=\(deviceName, privacy: .public), uid=\(deviceUID, privacy: .public)")
        logger.notice(
            "🎙️ Device details: transport=\(transportType, privacy: .public), manufacturer=\(manufacturer, privacy: .public)"
        )

        // Get buffer frame size
        if let bufferSize = getBufferFrameSize(deviceID: deviceID) {
            let latencyMs = (Double(bufferSize) / 48000.0) * 1000.0  // Approximate latency assuming 48kHz
            logger.notice(
                "🎙️ Buffer size: \(bufferSize, privacy: .public) frames, ~latency: \(String(format: "%.1f", latencyMs), privacy: .public)ms"
            )
        }
    }

    private func getDeviceStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var property: CFString?

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )

        if status == noErr, let cfString = property {
            return cfString as String
        }
        return nil
    }

    private func getTransportType(deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )

        if status != noErr {
            return "Unknown"
        }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeFireWire:
            return "FireWire"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeAVB:
            return "AVB"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        default:
            return "Other (\(transportType))"
        }
    }

    private func getBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var bufferSize: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &bufferSize
        )

        return status == noErr ? bufferSize : nil
    }

    private func getPreferredInputChannels(deviceID: AudioDeviceID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var channels = [UInt32](repeating: 0, count: 2)
        var propertySize = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let status = channels.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &propertySize,
                bytes.baseAddress!
            )
        }

        return status == noErr ? channels : nil
    }

    /// Checks if a device is currently available using Apple's kAudioDevicePropertyDeviceIsAlive
    private func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isAlive
        )

        return status == noErr && isAlive == 1
    }
}

// MARK: - Error Types

enum CoreAudioRecorderError: LocalizedError {
    case audioUnitNotFound
    case audioUnitNotInitialized
    case deviceNotAvailable
    case failedToCreateAudioUnit(status: OSStatus)
    case failedToEnableInput(status: OSStatus)
    case failedToDisableOutput(status: OSStatus)
    case failedToSetDevice(status: OSStatus)
    case failedToGetDeviceFormat(status: OSStatus)
    case failedToSetFormat(status: OSStatus)
    case failedToSetCallback(status: OSStatus)
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)
    case failedToInitialize(status: OSStatus)
    case failedToStart(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .audioUnitNotFound:
            return String(localized: "HAL Output AudioUnit not found")
        case .audioUnitNotInitialized:
            return String(localized: "AudioUnit not initialized")
        case .deviceNotAvailable:
            return String(localized: "Audio device is no longer available")
        case .failedToCreateAudioUnit(let status):
            return String(format: String(localized: "Failed to create AudioUnit: %lld"), Int64(status))
        case .failedToEnableInput(let status):
            return String(format: String(localized: "Failed to enable input: %lld"), Int64(status))
        case .failedToDisableOutput(let status):
            return String(format: String(localized: "Failed to disable output: %lld"), Int64(status))
        case .failedToSetDevice(let status):
            return String(format: String(localized: "Failed to set input device: %lld"), Int64(status))
        case .failedToGetDeviceFormat(let status):
            return String(format: String(localized: "Failed to get device format: %lld"), Int64(status))
        case .failedToSetFormat(let status):
            return String(format: String(localized: "Failed to set audio format: %lld"), Int64(status))
        case .failedToSetCallback(let status):
            return String(format: String(localized: "Failed to set input callback: %lld"), Int64(status))
        case .failedToCreateFile(let status):
            return String(format: String(localized: "Failed to create audio file: %lld"), Int64(status))
        case .failedToSetFileFormat(let status):
            return String(format: String(localized: "Failed to set file format: %lld"), Int64(status))
        case .failedToInitialize(let status):
            return String(format: String(localized: "Failed to initialize AudioUnit: %lld"), Int64(status))
        case .failedToStart(let status):
            return String(format: String(localized: "Failed to start AudioUnit: %lld"), Int64(status))
        }
    }
}
