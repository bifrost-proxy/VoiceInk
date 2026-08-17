import AVFoundation
import CoreAudio
import Foundation
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: CoreAudioRecorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var audioDeviceChangedObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    // Meter rendering is visual-only. Keep it below the capture/write queue so
    // CPU pressure cannot trade recorded audio for fresher animation frames.
    private let audioMeterQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audiometer", qos: .utility)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private let recordingAudioActionDelayNanoseconds: UInt64 = 220_000_000
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0
    private let audioMeterDeliveryBuffer = AudioMeterDeliveryBuffer()

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }

    enum RecorderError: Error {
        case couldNotStartRecording
    }

    override init() {
        super.init()
        setupDeviceSwitchObserver()
        setupAudioDeviceChangedObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleDeviceSwitchRequired(notification)
            }
        }
    }

    private func setupAudioDeviceChangedObserver() {
        audioDeviceChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "device-changed")
            }
        }
    }

    private func handleDeviceSwitchRequired(_ notification: Notification) async {
        guard !isReconfiguring else { return }
        guard let recorder = recorder else { return }
        guard let userInfo = notification.userInfo,
            let newDeviceID = userInfo["newDeviceID"] as? AudioDeviceID
        else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try recorder.switchDevice(to: newDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Switched to: %@"), deviceName),
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error, privacy: .public)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        deviceManager.isRecordingActive = true

        let currentDeviceID = deviceManager.getCurrentDevice()
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Using: %@"), deviceName),
                    type: .info
                )
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let deviceID = currentDeviceID

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        audioMeterUpdateTimer?.cancel()
        pauseMedia()
        muteSystemAudio()

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        do {
            // Offload hardware start to avoid shortcut lag.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            startAudioMeterTimer()
        } catch {
            logger.error(
                "Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
            )
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil
        audioMeterDeliveryBuffer.deactivate()

        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }
        onAudioChunk = nil

        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
        deviceManager.isRecordingActive = false
    }

    private func muteSystemAudio() {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.recordingAudioActionDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    private func pauseMedia() {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia()
        }
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error, privacy: .public)")

        // Stop the recording
        await stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Recording Failed: %@"), error.localizedDescription),
                type: .error
            )
        }
    }

    private func startAudioMeterTimer() {
        audioMeterDeliveryBuffer.activate()
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(AudioMeterRenderingPolicy.updateIntervalMilliseconds),
            leeway: .milliseconds(AudioMeterRenderingPolicy.timerLeewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            self?.updateAudioMeter()
        }
        timer.resume()
        audioMeterUpdateTimer = timer
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID)
            } catch {
                logger.warning(
                    "Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    private func updateAudioMeter() {
        guard let recorder = recorder else { return }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage =
            smoothedAverage * AudioMeterRenderingPolicy.smoothingRetention
            + normalizedAverage * (1 - AudioMeterRenderingPolicy.smoothingRetention)
        smoothedPeak =
            smoothedPeak * AudioMeterRenderingPolicy.smoothingRetention
            + normalizedPeak * (1 - AudioMeterRenderingPolicy.smoothingRetention)
        let newAudioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        smoothedValuesLock.unlock()

        // Keep at most one main-thread delivery pending. When inference or
        // another workload is busy, stale meter frames are replaced by the
        // newest sample instead of building a queue that makes the UI lag.
        guard audioMeterDeliveryBuffer.submit(newAudioMeter) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                let latestMeter = self.audioMeterDeliveryBuffer.takeLatestValue()
            else {
                return
            }
            guard AudioMeterRenderingPolicy.shouldPublish(previous: self.audioMeter, next: latestMeter) else {
                return
            }
            self.audioMeter = latestMeter
        }
    }

    // MARK: - Cleanup

    deinit {
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioMeterUpdateTimer?.cancel()
        audioRestorationTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioDeviceChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder?.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}

enum AudioMeterRenderingPolicy {
    /// 30 fps remains responsive for a small audio meter while halving the
    /// observable-object invalidations produced by the previous 60 fps loop.
    static let updateIntervalMilliseconds = 33
    static let timerLeewayMilliseconds = 6
    static let minimumVisibleDelta = 0.006
    /// Preserves roughly the same response time as the former 60 fps sampler.
    static let smoothingRetention: Float = 0.36

    static func shouldPublish(previous: AudioMeter, next: AudioMeter) -> Bool {
        abs(previous.averagePower - next.averagePower) >= minimumVisibleDelta
            || abs(previous.peakPower - next.peakPower) >= minimumVisibleDelta
    }
}

/// Thread-safe single-slot buffer used to coalesce audio-meter deliveries to
/// the main actor. It intentionally stores only the most recent visual frame.
final class AudioMeterDeliveryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var latestValue: AudioMeter?
    private var isDeliveryScheduled = false
    private var isActive = false

    func activate() {
        lock.lock()
        isActive = true
        lock.unlock()
    }

    /// Returns true only when the caller needs to schedule a main-thread drain.
    func submit(_ value: AudioMeter) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isActive else { return false }
        latestValue = value
        guard !isDeliveryScheduled else { return false }
        isDeliveryScheduled = true
        return true
    }

    func takeLatestValue() -> AudioMeter? {
        lock.lock()
        defer { lock.unlock() }

        let value = latestValue
        latestValue = nil
        isDeliveryScheduled = false
        return value
    }

    /// Stops accepting samples and clears any value captured by an event that
    /// was already running when its dispatch timer was cancelled.
    func deactivate() {
        lock.lock()
        isActive = false
        latestValue = nil
        lock.unlock()
    }
}
