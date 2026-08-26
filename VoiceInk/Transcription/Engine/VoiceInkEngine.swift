import AVFoundation
import AppKit
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var hasReceivedFirstChunk = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onFirstChunk: @Sendable () -> Void

    init(onFirstChunk: @escaping @Sendable () -> Void = {}) {
        self.onFirstChunk = onFirstChunk
    }

    func receive(_ data: Data) {
        let result = state.withLock { state -> (callback: ((Data) -> Void)?, isFirstChunk: Bool) in
            let isFirstChunk = !state.hasReceivedFirstChunk
            state.hasReceivedFirstChunk = true
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return (nil, isFirstChunk)
            }
            return (state.callback, isFirstChunk)
        }
        if result.isFirstChunk {
            onFirstChunk()
        }
        result.callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

private actor RecordingContextWaitRace {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}

@MainActor
final class RecordingDurationLimiter {
    static let absoluteMaximumDuration: Duration = .seconds(600)

    private var limitTask: Task<Void, Never>?
    private(set) var scheduledRecordingID: UUID?

    static func clampedDuration(_ duration: Duration) -> Duration {
        min(max(duration, .zero), absoluteMaximumDuration)
    }

    func schedule(
        recordingID: UUID,
        duration: Duration,
        onLimitReached: @MainActor @escaping (UUID) async -> Void
    ) {
        cancel()
        scheduledRecordingID = recordingID
        let effectiveDuration = Self.clampedDuration(duration)
        limitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: effectiveDuration)
            } catch {
                return
            }

            guard let self, scheduledRecordingID == recordingID else { return }
            scheduledRecordingID = nil
            limitTask = nil
            await onLimitReached(recordingID)
        }
    }

    func cancel() {
        limitTask?.cancel()
        limitTask = nil
        scheduledRecordingID = nil
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    @Published private(set) var recordingPermissionGuidance: RecorderPermissionGuidance?
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRealtimeSessionID: UUID?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var activePipelineTranscription: Transcription?
    private var activePipelineTask: Task<Void, Never>?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var enhancementBypassTranscriptionIDs = Set<UUID>()
    private let enhancementBypassDelivery = TranscriptionDelivery()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: RecordingContextCaptureTasks?
    private var activeRecordingContextModeID: UUID?
    private var activeRecordingContextTarget: RecordingContextTarget?
    private var activeRecordingVocabularyUsageContext: VocabularyUsageContext = .none
    private var activeRecordingModeTask: Task<VocabularyUsageContext, Never>?
    private var activeRecordingInputTarget: RecordingInputTarget?
    private var activePipelineInputTarget: RecordingInputTarget?
    private var pendingPermissionModeId: UUID?
    private var isPermissionAuthorizationInProgress = false
    private let recordingDurationLimiter = RecordingDurationLimiter()

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(
        modeId: UUID? = nil,
        isAssistantFollowUp: Bool = false,
        onCaptureStarted: (@MainActor () -> Void)? = nil
    ) async {
        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            recordingDurationLimiter.cancel()
            let modeTask = activeRecordingModeTask
            activePipelineUseCase = activeRecordingUseCase
            activeRecordingUseCase = .newSession
            activePipelineInputTarget = activeRecordingInputTarget
            activeRecordingInputTarget = nil
            recordingState = .transcribing
            await recorder.stopRecording()
            let captureIntegritySnapshot = recorder.lastCaptureIntegritySnapshot

            guard captureIntegritySnapshot.hasAudioForTranscription else {
                modeTask?.cancel()
                activeRecordingModeTask = nil
                activeRecordingStartID = nil
                await discardRecordingWithoutAudio()
                return
            }

            // A short browser recording can stop while URL detection is still
            // running. Finish that recording-scoped lookup before selecting the
            // fallback file-transcription configuration.
            if let resolvedUsageContext = await modeTask?.value {
                activeRecordingVocabularyUsageContext = resolvedUsageContext
            }
            refreshRecordingContextForResolvedMode(target: activeRecordingContextTarget)
            activeRecordingModeTask = nil
            activeRecordingStartID = nil

            if captureIntegritySnapshot.hasCaptureLoss {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Some audio frames were dropped; this transcription may be incomplete"),
                    type: .warning,
                    duration: 6.0
                )
            }

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    let contextStore = activeRecordingContextStore
                    let pipelineTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.runPipeline(
                            on: transcription,
                            audioURL: recordedFile,
                            contextStore: contextStore
                        )
                    }
                    activePipelineTask = pipelineTask
                    await pipelineTask.value
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                if !shouldCancelRecording {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            recordingDurationLimiter.cancel()
            shouldCancelRecording = false
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()
            cancelActiveRecordingModeTask()
            activeRecordingVocabularyUsageContext = .none
            activeRecordingInputTarget = recordingUseCase.isAssistantFollowUp
                ? nil
                : RecordingInputTargetService.capture()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            guard ensureRecordingPermissions(modeId: modeId) else {
                activeRecordingInputTarget = nil
                return
            }

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        guard await self.passesRecordingPreflight(modeId: modeId) else {
                            self.activeRecordingInputTarget = nil
                            return
                        }

                        let startID = UUID()
                        self.activeRecordingStartID = startID
                        let lockedTarget = RecordingContextTarget.captureIdentity()
                        var activeModeTask: Task<VocabularyUsageContext, Never>?
                        let stateBeforeRecorderStart = self.recordingState
                        let permanentURL = self.recordingsDirectory.appendingPathComponent(
                            "\(UUID().uuidString).wav"
                        )

                        do {
                            let captureRequestedAt = DispatchTime.now().uptimeNanoseconds
                            let diagnosticsLogger = self.logger
                            let realtimeAudioGate = RealtimeAudioChunkGate {
                                let elapsedMilliseconds = Double(
                                    DispatchTime.now().uptimeNanoseconds - captureRequestedAt
                                ) / 1_000_000
                                diagnosticsLogger.notice(
                                    "Recording startup milestone=firstConvertedPCM elapsedMs=\(elapsedMilliseconds, privacy: .public) recordingID=\(startID.uuidString, privacy: .public)"
                                )
                            }
                            self.recorder.onAudioChunk = realtimeAudioGate.receive

                            self.recordingState = .starting
                            try await self.recorder.startRecording(toOutputFile: permanentURL)
                            let audioUnitReadyMilliseconds = Double(
                                DispatchTime.now().uptimeNanoseconds - captureRequestedAt
                            ) / 1_000_000
                            self.logger.notice(
                                "Recording startup milestone=audioUnitStarted elapsedMs=\(audioUnitReadyMilliseconds, privacy: .public) recordingID=\(startID.uuidString, privacy: .public)"
                            )

                            guard self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                activeModeTask?.cancel()
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    if self.recordingState == .starting {
                                        self.recordingState = stateBeforeRecorderStart
                                    }
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            // The replacement is real only after recorder startup
                            // succeeds. Disown the old pipeline before publishing
                            // the new URL, so its late cleanup cannot clear this
                            // capture and a failed startup cannot discard old work.
                            self.cancelSupersededPipelineForNewRecording()
                            self.activePipelineTranscriptionID = nil
                            self.recordedFile = permanentURL
                            self.partialTranscript = ""

                            // Capture is deliberately started before panel creation, mode matching,
                            // context capture, or cloud session setup. The realtime gate preserves
                            // every converted chunk until the selected session is ready.
                            self.recordingState = .recording
                            onCaptureStarted?()
                            let recordingDurationMinutes = RecordingDurationSettings.currentMinutes()
                            self.recordingDurationLimiter.schedule(
                                recordingID: startID,
                                duration: .seconds(recordingDurationMinutes * 60)
                            ) { [weak self] recordingID in
                                await self?.stopRecordingAtDurationLimit(recordingID: recordingID)
                            }

                            let modeApplication = ActiveWindowService.shared.beginApplyingConfiguration(
                                modeId: modeId,
                                target: lockedTarget,
                                resolveVocabularyDomain: TranscriptionVocabularyContext.hasDomainVocabulary(
                                    in: self.modelContext
                                )
                            ) { [weak self] in
                                guard let self else { return false }
                                return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                            }
                            activeModeTask = modeApplication.completion
                            self.activeRecordingModeTask = modeApplication.completion
                            self.activeRecordingVocabularyUsageContext = modeApplication.initialUsageContext
                            let contextTarget = self.recordingContextTarget(
                                from: lockedTarget,
                                modeId: modeId
                            )
                            let shouldPrepareRecognitionContext = self.startRecordingContextCapture(
                                modeId: modeId,
                                target: contextTarget
                            )
                            let canPrepareStreamingImmediately = !modeApplication.waitsForBrowserURL
                                && !shouldPrepareRecognitionContext

                            if canPrepareStreamingImmediately {
                                guard
                                    try await self.prepareTranscriptionSession(
                                        startID: startID,
                                        realtimeAudioGate: realtimeAudioGate,
                                        recognitionContext: nil
                                    )
                                else {
                                    activeModeTask?.cancel()
                                    await self.abortRecordingStartup(permanentURL: permanentURL)
                                    return
                                }
                            }

                            if let resolvedUsageContext = await activeModeTask?.value {
                                self.activeRecordingVocabularyUsageContext = resolvedUsageContext
                            }
                            self.activeRecordingModeTask = nil

                            guard self.recordingState == .recording,
                                self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                return
                            }

                            if modeApplication.waitsForBrowserURL {
                                self.refreshRecordingContextForResolvedMode(target: contextTarget)
                            }

                            if !canPrepareStreamingImmediately {
                                let recognitionContext = await self.initialRecognitionContext()
                                guard self.recordingState == .recording,
                                    self.activeRecordingStartID == startID,
                                    !self.shouldCancelRecording
                                else { return }
                                guard
                                    try await self.prepareTranscriptionSession(
                                        startID: startID,
                                        realtimeAudioGate: realtimeAudioGate,
                                        recognitionContext: recognitionContext
                                    )
                                else {
                                    await self.abortRecordingStartup(permanentURL: permanentURL)
                                    return
                                }
                            }

                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                                    transcriptionModelManager: self.transcriptionModelManager
                                )?.model

                                if let model = currentModel,
                                    model.provider == .whisper
                                {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: {
                                        $0.name == model.name
                                    }),
                                        self.whisperModelManager.whisperContext == nil
                                    {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(
                                        for: fluidAudioModel)
                                }

                            }

                        } catch {
                            activeModeTask?.cancel()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            await self.recorder.stopRecording()
                            try? FileManager.default.removeItem(at: permanentURL)
                            if self.activeRecordingStartID == startID {
                                self.activeRecordingStartID = nil
                            }
                            if self.recordingState == .starting {
                                self.recordingState = stateBeforeRecorderStart
                            }
                            self.clearActiveRecordingContext()
                            self.activeRecordingUseCase = .newSession
                            self.activeRecordingInputTarget = nil
                            NotificationManager.shared.showNotification(
                                title: String(localized: "Recording failed to start"), type: .error)
                            await self.recorderUIManager?.dismissRecorderPanel()
                        }
                    }
                } else {
                    logger.error("Recording permission denied")
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.activeRecordingInputTarget = nil
                        await self.beginRecordingPermissionRecovery(modeId: modeId)
                    }
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping @MainActor @Sendable (Bool) -> Void) {
        Task { @MainActor in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                response(true)
            case .notDetermined:
                response(await AVCaptureDevice.requestAccess(for: .audio))
            case .denied, .restricted:
                response(false)
            @unknown default:
                response(false)
            }
        }
    }

    private func stopRecordingAtDurationLimit(recordingID: UUID) async {
        guard activeRecordingStartID == recordingID, recordingState == .recording else { return }

        logger.notice("Stopping recording after reaching the configured duration limit")
        NotificationManager.shared.showNotification(
            title: String(localized: "Recording stopped after reaching the duration limit"),
            type: .warning,
            duration: 5.0
        )
        await toggleRecord()
    }

    // MARK: - Recording Preflight

    /// Resolves the already-selected mode and starts its streaming session.
    /// For explicit and non-browser modes this runs before CoreAudio startup so
    /// the one cloud connection can overlap recorder initialization. Browser
    /// URL modes call it only after URL resolution has selected the final model.
    private func prepareTranscriptionSession(
        startID: UUID,
        realtimeAudioGate: RealtimeAudioChunkGate,
        recognitionContext: RecognitionContextEnvelope?
    ) async throws -> Bool {
        let modelResolution = ModeRuntimeResolver.transcriptionModelResolution(
            transcriptionModelManager: transcriptionModelManager
        )
        if let failure = recordingReadinessFailure(for: modelResolution) {
            NotificationManager.shared.showNotification(
                title: failure.title,
                type: .error,
                duration: 7.0,
                actionButton: (failure.actionLabel, failure.action)
            )
            return false
        }
        guard
            let resolvedConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                from: modelResolution
            )
        else {
            preconditionFailure("Recording readiness accepted an unavailable transcription model")
        }

        let vocabulary = TranscriptionVocabularyContext.resolve(
            from: modelContext,
            usageContext: activeRecordingVocabularyUsageContext,
            model: resolvedConfiguration.model,
            isRealtimeEnabled: resolvedConfiguration.isRealtimeEnabled
        )
        let transcriptionConfiguration = resolvedConfiguration
            .addingSpeechRecognitionContext(recognitionContext)
            .addingVocabulary(vocabulary)
        logger.notice(
            "Vocabulary resolved selected=\(vocabulary.terms.count, privacy: .public) applicable=\(vocabulary.applicableTerms.count, privacy: .public) domain=\(vocabulary.domainUsed, privacy: .public) application=\(vocabulary.applicationUsed, privacy: .public) global=\(vocabulary.globalUsed, privacy: .public) omitted=\(vocabulary.omittedCount, privacy: .public)"
        )

        guard serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) else {
            currentSession = nil
            activeRealtimeSessionID = nil
            currentSessionTranscriptionConfiguration = transcriptionConfiguration
            recorder.onAudioChunk = nil
            _ = realtimeAudioGate.reset()
            return true
        }

        let realtimeSessionID = UUID()
        activeRealtimeSessionID = realtimeSessionID
        let session = serviceRegistry.createSession(
            for: transcriptionConfiguration,
            onPartialTranscript: { [weak self] partial in
                guard let self,
                    self.activeRealtimeSessionID == realtimeSessionID,
                    self.recordingState == .recording || self.recordingState == .transcribing
                else {
                    return
                }
                self.partialTranscript = partial
            }
        )
        currentSession = session
        currentSessionTranscriptionConfiguration = transcriptionConfiguration
        let realCallback = try await session.prepare(configuration: transcriptionConfiguration)

        guard activeRecordingStartID == startID,
            recordingState == .recording,
            !shouldCancelRecording,
            currentSession === session
        else {
            session.cancel()
            if activeRealtimeSessionID == realtimeSessionID {
                activeRealtimeSessionID = nil
            }
            _ = realtimeAudioGate.reset()
            recorder.onAudioChunk = nil
            return true
        }

        if let realCallback {
            let droppedStartupChunks = realtimeAudioGate.activate(realCallback)
            if droppedStartupChunks > 0 {
                session.recordDroppedAudioChunks(droppedStartupChunks)
                logger.warning(
                    "Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active"
                )
            }
        } else {
            _ = realtimeAudioGate.reset()
            recorder.onAudioChunk = nil
        }
        return true
    }

    private func abortRecordingStartup(permanentURL: URL) async {
        await recorder.stopRecording()
        cancelCurrentSession()
        try? FileManager.default.removeItem(at: permanentURL)
        recordedFile = nil
        recordingState = .idle
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await cleanupResources()
        await recorderUIManager?.dismissRecorderPanel()
    }

    func prepareRecordingPermissionRecovery(modeId: UUID? = nil) {
        let recoveryModeId = modeId ?? pendingPermissionModeId
        pendingPermissionModeId = recoveryModeId

        if let issue = RecordingPermissionPreflight.firstMissingPermission(
            requiresScreenRecording: modeRequiresScreenRecording(recoveryModeId)
        ) {
            recordingState = .idle
            recordingPermissionGuidance = .required(issue)
        } else {
            pendingPermissionModeId = nil
            recordingPermissionGuidance = .ready
        }
    }

    func beginRecordingPermissionRecovery(modeId: UUID? = nil) async {
        let recoveryModeId = modeId ?? pendingPermissionModeId
        pendingPermissionModeId = recoveryModeId

        guard
            let issue = RecordingPermissionPreflight.firstMissingPermission(
                requiresScreenRecording: modeRequiresScreenRecording(recoveryModeId)
            )
        else {
            pendingPermissionModeId = nil
            recordingPermissionGuidance = .ready
            return
        }

        guard !isPermissionAuthorizationInProgress else { return }
        isPermissionAuthorizationInProgress = true
        recordingState = .idle
        recordingPermissionGuidance = .requesting(issue)

        // The permission dialog belongs to VoiceInk. Bring the app forward and
        // yield a render pass so the recorder guidance becomes visible before
        // macOS presents any system UI.
        NSApplication.shared.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = await RecordingPermissionPreflight.requestAuthorization(for: issue)
        isPermissionAuthorizationInProgress = false
        refreshRecordingPermissionGuidance()
    }

    func refreshRecordingPermissionGuidance() {
        guard recordingPermissionGuidance != nil else { return }
        guard !isPermissionAuthorizationInProgress else { return }
        let nextIssue = RecordingPermissionPreflight.firstMissingPermission(
            requiresScreenRecording: modeRequiresScreenRecording(pendingPermissionModeId)
        )
        if let nextIssue {
            recordingPermissionGuidance = .required(nextIssue)
        } else {
            pendingPermissionModeId = nil
            recordingPermissionGuidance = .ready
        }
    }

    func clearRecordingPermissionGuidance() {
        recordingPermissionGuidance = nil
        pendingPermissionModeId = nil
    }

    private func ensureRecordingPermissions(modeId: UUID?) -> Bool {
        pendingPermissionModeId = modeId
        if let issue = RecordingPermissionPreflight.firstMissingPermission(
            requiresScreenRecording: modeRequiresScreenRecording(modeId)
        ) {
            recordingState = .idle
            recordingPermissionGuidance = .required(issue)
            return false
        }

        clearRecordingPermissionGuidance()
        return true
    }

    private func modeRequiresScreenRecording(_ modeId: UUID?) -> Bool {
        recordingContextPlan(modeId: modeId).needsScreenOCR
    }

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No mode configured"),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' mode"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' mode is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model):
            if let issue = ModeConnectionRequirements.transcriptionIssue(
                for: model,
                hasAPIKey: APIKeyManager.shared.hasAPIKey
            ) {
                return providerConnectionFailure(for: issue)
            }
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        case .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    private func providerConnectionFailure(
        for issue: ModeProviderConnectionIssue
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        let title: String
        switch issue {
        case .missingAPIKey(let providerKey):
            title = String(
                format: String(localized: "%@ is not connected. Configure its API key to use this mode."),
                providerKey
            )
        case .incompleteConfiguration(let providerKey):
            title = String(
                format: String(localized: "%@ is not fully configured. Finish its setup to use this mode."),
                providerKey
            )
        }

        return (
            title,
            String(localized: "Configure API Key"),
            { ModeSetupNavigator.openModelsSettings(forProvider: issue.providerKey) }
        )
    }

    private func recordingReadinessFailure(
        for transcriptionResolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void)? {
        guard ModeRuntimeResolver.transcriptionConfiguration(from: transcriptionResolution) != nil else {
            return recordingModelFailure(for: transcriptionResolution)
        }

        let mode: ModeConfig?
        switch transcriptionResolution {
        case .available(let resolvedMode, _):
            mode = resolvedMode
        case .noMode, .noSelection, .modelNotFound, .unavailable:
            mode = nil
        }

        if let issue = ModeConnectionRequirements.enhancementIssue(
            for: mode,
            hasAPIKey: APIKeyManager.shared.hasAPIKey
        ) {
            return providerConnectionFailure(for: issue)
        }

        return nil
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight(modeId: UUID?) async -> Bool {
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        let mode = modeId.flatMap(ModeManager.shared.getConfiguration(with:))
            ?? ModeManager.shared.currentEffectiveConfiguration
        let resolution = ModeRuntimeResolver.transcriptionModelResolution(
            mode: mode,
            transcriptionModelManager: transcriptionModelManager
        )
        if let failure = recordingReadinessFailure(for: resolution) {
            await failRecordingPreflight(
                title: failure.title,
                actionLabel: failure.actionLabel,
                action: failure.action
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Recording Context

    private func recordingContextPlan(modeId: UUID?) -> RecordingContextCapturePlan {
        let mode = modeId.flatMap(ModeManager.shared.getConfiguration(with:))
            ?? ModeManager.shared.currentEffectiveConfiguration
        guard let mode else { return .none }
        let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            mode: mode,
            transcriptionModelManager: transcriptionModelManager
        )
        let providerConfiguration = configuration.flatMap {
            RecognitionContextProviderConfiguration.current(for: $0.model.provider)
        }
        return RecognitionContextPolicy.capturePlan(
            mode: mode,
            providerConfiguration: providerConfiguration
        )
    }

    private func recordingContextTarget(
        from target: RecordingContextTarget?,
        modeId: UUID?
    ) -> RecordingContextTarget? {
        guard recordingContextPlan(modeId: modeId).needsWindowContext else { return target }
        return target?.capturingWindowContext()
    }

    @discardableResult
    private func startRecordingContextCapture(
        modeId: UUID?,
        target: RecordingContextTarget?
    ) -> Bool {
        clearActiveRecordingContext()
        activeRecordingContextTarget = target

        let mode = modeId.flatMap(ModeManager.shared.getConfiguration(with:))
            ?? ModeManager.shared.currentEffectiveConfiguration
        guard let mode else { return false }
        activeRecordingContextModeID = mode.id
        let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            mode: mode,
            transcriptionModelManager: transcriptionModelManager
        )
        let providerConfiguration = configuration.flatMap {
            RecognitionContextProviderConfiguration.current(for: $0.model.provider)
        }
        let plan = RecognitionContextPolicy.capturePlan(
            mode: mode,
            providerConfiguration: providerConfiguration
        )
        guard !plan.sources.isEmpty else { return false }
        let store = RecordingContextSnapshotStore(target: target)
        activeRecordingContextStore = store
        let captureTasks = RecordingContextCaptureService.startCapture(
            plan: plan,
            target: target,
            into: store
        )
        activeRecordingContextTasks = captureTasks

        return !RecognitionContextPolicy.asrSources(
            mode: mode,
            providerConfiguration: providerConfiguration
        ).isEmpty
    }

    private func refreshRecordingContextForResolvedMode(target: RecordingContextTarget?) {
        let resolvedModeID = ModeManager.shared.currentEffectiveConfiguration?.id
        guard RecordingContextModeResolution.needsCaptureRefresh(
            capturedModeID: activeRecordingContextModeID,
            resolvedModeID: resolvedModeID
        ) else { return }
        let contextTarget = recordingContextTarget(from: target, modeId: resolvedModeID)
        _ = startRecordingContextCapture(modeId: resolvedModeID, target: contextTarget)
    }

    private func initialRecognitionContext() async -> RecognitionContextEnvelope? {
        guard
            let store = activeRecordingContextStore,
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            ),
            let providerConfiguration = RecognitionContextProviderConfiguration.current(
                for: configuration.model.provider
            )
        else { return nil }

        let asrSources = RecognitionContextPolicy.asrSources(
            mode: configuration.mode,
            providerConfiguration: providerConfiguration
        )
        var tasks: [Task<Void, Never>] = []
        if asrSources.contains(.selectedText), let task = activeRecordingContextTasks?.selectedText {
            tasks.append(task)
        }
        if asrSources.contains(.clipboard), let task = activeRecordingContextTasks?.clipboard {
            tasks.append(task)
        }
        _ = await waitForInitialContextTasks(tasks, timeout: .seconds(1))
        guard !Task.isCancelled, activeRecordingContextStore === store else { return nil }
        let envelope = SpeechRecognitionContextBuilder.build(
            snapshot: store.snapshot,
            mode: configuration.mode,
            providerConfiguration: providerConfiguration
        )
        logRecognitionContext(envelope, provider: configuration.model.provider)
        return envelope
    }

    private func waitForInitialContextTasks(
        _ tasks: [Task<Void, Never>],
        timeout: Duration
    ) async -> Bool {
        guard !tasks.isEmpty else { return true }
        let race = RecordingContextWaitRace()
        let completionWatcher = Task {
            for task in tasks { await task.value }
            await race.resolve(true)
        }
        let timeoutWatcher = Task {
            do {
                try await Task.sleep(for: timeout)
                await race.resolve(false)
            } catch {}
        }
        let completed = await race.wait()
        completionWatcher.cancel()
        timeoutWatcher.cancel()
        return completed
    }

    private func logRecognitionContext(_ envelope: RecognitionContextEnvelope?, provider: ModelProvider) {
        let serialization = provider == .doubaoSpeech
            ? DoubaoRecognitionContextSerializer.serialize(envelope)
            : QwenRecognitionContextSerializer.serialize(envelope)
        let hotwordCount = currentSessionTranscriptionConfiguration?.vocabulary?.terms.count
            ?? TranscriptionVocabularyContext.uniqueTerms(from: modelContext).count
        let summary = RecognitionContextLogSummary.make(
            provider: provider,
            serialization: serialization,
            hotwordCount: hotwordCount
        )
        logger.notice("\(summary, privacy: .public)")
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks?.cancelAll()
        activeRecordingContextTasks = nil
        activeRecordingContextStore = nil
        activeRecordingContextModeID = nil
        activeRecordingContextTarget = nil
    }

    private func cancelActiveRecordingModeTask() {
        activeRecordingModeTask?.cancel()
        activeRecordingModeTask = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?
    ) async {
        guard let baseConfiguration = currentSessionTranscriptionConfiguration
            ?? ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            activePipelineUseCase = .newSession
            activePipelineInputTarget = nil
            return
        }
        let contextAwareBaseConfiguration: TranscriptionRuntimeConfiguration
        if baseConfiguration.speechRecognitionContext != nil {
            contextAwareBaseConfiguration = baseConfiguration
        } else {
            let recognitionContext = await initialRecognitionContext()
            contextAwareBaseConfiguration = baseConfiguration.addingSpeechRecognitionContext(recognitionContext)
        }

        let transcriptionConfiguration: TranscriptionRuntimeConfiguration
        if contextAwareBaseConfiguration.vocabulary != nil {
            transcriptionConfiguration = contextAwareBaseConfiguration
        } else {
            // Session setup can be overtaken by a very short recording. Resolve
            // the same recording-scoped snapshot here instead of falling back
            // to the legacy global-only request context.
            let vocabulary = TranscriptionVocabularyContext.resolve(
                from: modelContext,
                usageContext: activeRecordingVocabularyUsageContext,
                model: contextAwareBaseConfiguration.model,
                isRealtimeEnabled: contextAwareBaseConfiguration.isRealtimeEnabled
            )
            transcriptionConfiguration = contextAwareBaseConfiguration.addingVocabulary(vocabulary)
        }

        let session = currentSession
        let realtimeSessionID = activeRealtimeSessionID
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID
        activePipelineTranscription = transcription

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            inputTarget: activePipelineInputTarget,
            captureIntegritySnapshot: recorder.lastCaptureIntegritySnapshot,
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.partialTranscript = RecorderTranscriptPresentation.text(
                    for: state,
                    currentText: self.partialTranscript,
                    finalizedTranscript: transcription.text
                )
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            shouldBypassEnhancement: { [weak self] in
                self?.enhancementBypassTranscriptionIDs.contains(transcriptionID) == true
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            await finishRecorderSession()
            await cleanupResources()
            activePipelineTranscriptionID = nil
            activePipelineTranscription = nil
            activePipelineTask = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            if activeRealtimeSessionID == realtimeSessionID {
                activeRealtimeSessionID = nil
            }
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            activePipelineInputTarget = nil
            clearActiveRecordingContext()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)
        enhancementBypassTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline
            && (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy)
        {
            recordingState = .idle
        }
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return processedText
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = true
        case .transcribing, .enhancing:
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    /// Stops only the AI enhancement phase and immediately returns the completed raw transcript.
    func cancelEnhancementAndPasteOriginal() async {
        guard recordingState == .enhancing,
            let transcriptionID = activePipelineTranscriptionID,
            !enhancementBypassTranscriptionIDs.contains(transcriptionID),
            let transcription = activePipelineTranscription
        else {
            return
        }

        let originalText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalText.isEmpty else { return }

        enhancementBypassTranscriptionIDs.insert(transcriptionID)
        activePipelineTask?.cancel()
        partialTranscript = originalText
        recordingState = .busy

        await enhancementBypassDelivery.pasteOriginalImmediately(
            originalText,
            inputTarget: activePipelineInputTarget
        ) { [weak self] in
            await self?.recorderUIManager?.dismissRecorderPanel()
        }
    }

    func resetRecordingSession() async {
        cancelCurrentSession()
        cancelActiveRecordingModeTask()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        activePipelineTranscription = nil
        activePipelineTask?.cancel()
        activePipelineTask = nil
        canceledPipelineTranscriptionIDs.removeAll()
        enhancementBypassTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        activeRecordingInputTarget = nil
        activePipelineInputTarget = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
        await finishRecorderSession()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true
        cancelActiveRecordingModeTask()

        if (recordingState == .transcribing || recordingState == .enhancing),
            let activePipelineTranscriptionID
        {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        cancelActiveRecordingModeTask()
        activeRecordingStartID = nil
        activeRecordingInputTarget = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            vocabularyUsageContext: activeRecordingVocabularyUsageContext,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
        activeRealtimeSessionID = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
        activeRealtimeSessionID = nil
    }

    private func cancelSupersededPipelineForNewRecording() {
        if let activePipelineTranscriptionID {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }
        activePipelineTask?.cancel()
        cancelCurrentSession()
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    private func discardRecordingWithoutAudio() async {
        logger.warning("Recording stopped without any converted audio frames; skipping transcription")
        cancelCurrentSession()

        if let recordedFile, FileManager.default.fileExists(atPath: recordedFile.path) {
            do {
                try FileManager.default.removeItem(at: recordedFile)
            } catch {
                logger.error(
                    "Failed to remove empty recording file=\(recordedFile.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }

        recordedFile = nil
        partialTranscript = ""
        shouldCancelRecording = false
        activePipelineUseCase = .newSession
        activePipelineInputTarget = nil
        clearActiveRecordingContext()
        recordingState = .idle

        await cleanupResources()
        await finishRecorderSession()
        await recorderUIManager?.dismissRecorderPanel()

        NotificationManager.shared.showNotification(
            title: String(localized: "No audio was received. Check your microphone and try again."),
            type: .error,
            duration: 5.0
        )
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        recordingDurationLimiter.cancel()
        cancelActiveRecordingModeTask()
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        activeRecordingInputTarget = nil
        activePipelineInputTarget = nil
        await serviceRegistry.releaseUnboundLocalModelResources()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
