import Foundation
import SwiftData
import SwiftUI
import os

enum RuntimePressureResourceReleasePolicy {
    static func canRelease(activeOperationCount: Int, isRecordingActive: Bool) -> Bool {
        activeOperationCount == 0 && !isRecordingActive
    }
}

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")
    private var modeConfigurationsObserver: NSObjectProtocol?
    private var recordingStoppedObserver: NSObjectProtocol?
    private var activeOperationCount = 0
    private var pressureReleaseRequested = false
    private var pressureReleaseTask: Task<Bool, Never>?
    private var pressureReleaseID: UUID?

    private(set) lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService(modelContext: modelContext)
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private(set) lazy var fluidAudioTranscriptionService = FluidAudioTranscriptionService()
    private(set) lazy var sherpaOnnxTranscriptionService = SherpaOnnxTranscriptionService()
    private(set) lazy var qwenMLXTranscriptionService = QwenMLXTranscriptionService()

    init(modelProvider: any WhisperModelProvider, modelsDirectory: URL, modelContext: ModelContext) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
        modeConfigurationsObserver = NotificationCenter.default.addObserver(
            forName: .modeConfigurationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleModeConfigurationsDidChange()
            }
        }
        recordingStoppedObserver = NotificationCenter.default.addObserver(
            forName: .recordingDidStop,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.pressureReleaseRequested == true else { return }
                await self?.releaseAllLocalModelResourcesForPressure()
            }
        }
    }

    deinit {
        if let modeConfigurationsObserver {
            NotificationCenter.default.removeObserver(modeConfigurationsObserver)
        }
        if let recordingStoppedObserver {
            NotificationCenter.default.removeObserver(recordingStoppedObserver)
        }
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .whisper:
            return localTranscriptionService
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .sherpaOnnx:
            return sherpaOnnxTranscriptionService
        case .qwenMlx:
            return qwenMLXTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        default:
            return cloudTranscriptionService
        }
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        await waitForPressureReleaseIfNeeded()
        try Task.checkCancellation()
        operationDidStart()
        defer { operationDidFinish() }
        let service = service(for: model.provider)
        logger.debug(
            "Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)"
        )
        return try await service.transcribe(audioURL: audioURL, model: model, context: context.scoped(to: model))
    }

    /// Creates a streaming or file-based session for the resolved transcription configuration.
    func createSession(
        for configuration: TranscriptionRuntimeConfiguration,
        onPartialTranscript: (@MainActor (String) -> Void)? = nil
    ) -> TranscriptionSession {
        let model = configuration.model

        if shouldUseRealtimeTranscription(for: configuration) {
            let streamingService = StreamingTranscriptionService(
                modelContext: modelContext,
                fluidAudioService: model.provider == .fluidAudio ? fluidAudioTranscriptionService : nil,
                sherpaOnnxService: model.provider == .sherpaOnnx ? sherpaOnnxTranscriptionService : nil,
                onPartialTranscript: onPartialTranscript,
                customVocabulary: configuration.vocabulary?.terms
            )
            let fallback = service(for: model.provider)
            return managedSession(
                StreamingTranscriptionSession(streamingService: streamingService, fallbackService: fallback)
            )
        } else {
            return managedSession(FileTranscriptionSession(service: service(for: model.provider)))
        }
    }

    /// Whether the resolved transcription configuration should use real-time transcription.
    func shouldUseRealtimeTranscription(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.isRealtimeEnabled
    }

    func releaseUnboundLocalModelResources() async {
        guard activeOperationCount == 0, !AudioDeviceManager.shared.isRecordingActive else {
            return
        }

        let boundModelNames = LocalModelResourceRetentionPolicy.boundModelNames(
            in: ModeManager.shared.configurations
        )

        await modelProvider?.releaseResourcesIfUnbound(boundModelNames: boundModelNames)

        let releasedFluidModels = await fluidAudioTranscriptionService.releaseResourcesIfUnbound(
            boundModelNames: boundModelNames
        )
        if !releasedFluidModels.isEmpty {
            logger.notice(
                "Released unbound FluidAudio models: \(releasedFluidModels.sorted().joined(separator: ","), privacy: .public)"
            )
        }

        if let releasedSherpaModel = await sherpaOnnxTranscriptionService.releaseResourcesIfUnbound(
            boundModelNames: boundModelNames
        ) {
            logger.notice("Released unbound sherpa-onnx model: \(releasedSherpaModel, privacy: .public)")
        }

        if let releasedQwenModel = await QwenMLXRuntime.shared.releaseResourcesIfUnbound(
            boundModelNames: boundModelNames
        ) {
            logger.notice("Released unbound Qwen MLX model: \(releasedQwenModel, privacy: .public)")
        }
    }

    /// Memory pressure is an explicit request to relinquish optional cached
    /// inference state, including models retained because a mode references
    /// them. A later transcription reloads the selected model on demand.
    @discardableResult
    func releaseAllLocalModelResourcesForPressure() async -> Bool {
        pressureReleaseRequested = true
        if let pressureReleaseTask {
            return await pressureReleaseTask.value
        }
        guard RuntimePressureResourceReleasePolicy.canRelease(
            activeOperationCount: activeOperationCount,
            isRecordingActive: AudioDeviceManager.shared.isRecordingActive
        ) else {
            return false
        }

        let releaseID = UUID()
        let releaseTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            let released = await self.performPressureResourceRelease()
            self.finishPressureResourceRelease(id: releaseID)
            return released
        }
        pressureReleaseID = releaseID
        pressureReleaseTask = releaseTask
        return await releaseTask.value
    }

    private func performPressureResourceRelease() async -> Bool {
        await modelProvider?.releaseAllResources()
        await fluidAudioTranscriptionService.cleanup()
        _ = await sherpaOnnxTranscriptionService.releaseAllResources()
        await QwenMLXRuntime.shared.stop()
        pressureReleaseRequested = false
        logger.notice("Released all idle local model resources under memory pressure")
        return true
    }

    private func finishPressureResourceRelease(id: UUID) {
        guard pressureReleaseID == id else { return }
        pressureReleaseID = nil
        pressureReleaseTask = nil
    }

    func cancelPressureResourceRelease() {
        pressureReleaseRequested = false
    }

    private func managedSession(_ session: TranscriptionSession) -> TranscriptionSession {
        ResourceManagedTranscriptionSession(
            session: session,
            onPrepare: { [weak self] in
                guard let self else { return false }
                await self.waitForPressureReleaseIfNeeded()
                guard !Task.isCancelled else { return false }
                self.operationDidStart()
                return true
            },
            onFinish: { [weak self] in
                self?.operationDidFinish()
            }
        )
    }

    private func waitForPressureReleaseIfNeeded() async {
        await pressureReleaseTask?.value
    }

    private func operationDidStart() {
        activeOperationCount += 1
    }

    private func operationDidFinish() {
        activeOperationCount = max(0, activeOperationCount - 1)
        guard activeOperationCount == 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.pressureReleaseRequested {
                await self.releaseAllLocalModelResourcesForPressure()
            } else {
                await self.releaseUnboundLocalModelResources()
            }
        }
    }

    private func handleModeConfigurationsDidChange() async {
        await releaseUnboundLocalModelResources()
    }
}
