import Foundation
import SwiftData
import SwiftUI
import os

enum RuntimePressureResourceReleasePolicy {
    static func canRelease(activeOperationCount: Int, isRecordingActive: Bool) -> Bool {
        activeOperationCount == 0 && !isRecordingActive
    }
}

enum RuntimePressureOperationPolicy {
    static func coordinatesLocalRuntime(for provider: ModelProvider) -> Bool {
        switch provider {
        case .whisper, .fluidAudio, .sherpaOnnx, .qwenMlx:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class RuntimePressureOperationCoordinator {
    static let shared = RuntimePressureOperationCoordinator()

    private var activeOperationCount = 0
    private var pendingRelease: (() async -> Bool)?
    private var recordingIsActive: (() -> Bool)?
    private var releaseTask: Task<Bool, Never>?
    private var releaseID: UUID?
    private var resourceReleaseParticipants: [UUID: () async -> Bool] = [:]
    private var optionalOperationsSuspended = false

    var hasActiveOperations: Bool { activeOperationCount > 0 }
    var isReleasingResources: Bool { releaseTask != nil }
    var hasPendingRelease: Bool { pendingRelease != nil }

    func beginOperation() async -> Bool {
        if let releaseTask {
            _ = await releaseTask.value
        }
        guard !Task.isCancelled else { return false }
        activeOperationCount += 1
        return true
    }

    func beginOptionalOperation() async -> Bool {
        guard !optionalOperationsSuspended else { return false }
        guard await beginOperation() else { return false }
        guard !optionalOperationsSuspended else {
            endOperation()
            return false
        }
        return true
    }

    func suspendOptionalOperations() {
        optionalOperationsSuspended = true
    }

    func resumeOptionalOperations() {
        optionalOperationsSuspended = false
    }

    func registerResourceReleaseParticipant(
        id: UUID,
        operation: @escaping () async -> Bool
    ) {
        resourceReleaseParticipants[id] = operation
    }

    func unregisterResourceReleaseParticipant(id: UUID) {
        resourceReleaseParticipants[id] = nil
    }

    func requestRegisteredResourceRelease(
        recordingIsActive: @escaping () -> Bool
    ) async -> Bool {
        await requestRelease(
            recordingIsActive: recordingIsActive,
            operation: { [weak self] in
                await self?.releaseRegisteredResources() ?? false
            }
        )
    }

    func endOperation() {
        activeOperationCount = max(0, activeOperationCount - 1)
        guard activeOperationCount == 0, pendingRelease != nil else { return }
        Task { @MainActor [weak self] in
            _ = await self?.startPendingReleaseIfPossible()
        }
    }

    func requestRelease(
        recordingIsActive: @escaping () -> Bool,
        operation: @escaping () async -> Bool
    ) async -> Bool {
        self.recordingIsActive = recordingIsActive
        pendingRelease = operation
        if let releaseTask {
            let released = await releaseTask.value
            if released { return true }
            return await startPendingReleaseIfPossible()
        }
        return await startPendingReleaseIfPossible()
    }

    func retryPendingRelease() async -> Bool {
        if let releaseTask {
            let released = await releaseTask.value
            if released { return true }
            return await startPendingReleaseIfPossible()
        }
        return await startPendingReleaseIfPossible()
    }

    func cancelPendingRelease() {
        pendingRelease = nil
        recordingIsActive = nil
        releaseTask?.cancel()
    }

    private func startPendingReleaseIfPossible() async -> Bool {
        guard releaseTask == nil,
            activeOperationCount == 0,
            recordingIsActive?() != true,
            let pendingRelease
        else {
            return false
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            let released = await pendingRelease()
            self?.finishRelease(id: id)
            return released
        }
        releaseID = id
        releaseTask = task
        return await task.value
    }

    private func finishRelease(id: UUID) {
        guard releaseID == id else { return }
        releaseID = nil
        releaseTask = nil
        // Keep a successful pressure-release request armed until an explicit
        // normal-pressure recovery cancels it. A required local operation may
        // reload a bound model while pressure remains elevated; endOperation()
        // must then trigger another release pass.
    }

    private func releaseRegisteredResources() async -> Bool {
        let operations = Array(resourceReleaseParticipants.values)
        for operation in operations {
            guard !Task.isCancelled, await operation() else { return false }
        }
        return !Task.isCancelled
    }
}

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let pressureOperations: RuntimePressureOperationCoordinator
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")
    private var modeConfigurationsObserver: NSObjectProtocol?
    private var recordingStoppedObserver: NSObjectProtocol?
    private let pressureReleaseParticipantID = UUID()

    private(set) lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService(modelContext: modelContext)
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private(set) lazy var fluidAudioTranscriptionService = FluidAudioTranscriptionService()
    private(set) lazy var sherpaOnnxTranscriptionService = SherpaOnnxTranscriptionService()
    private(set) lazy var qwenMLXTranscriptionService = QwenMLXTranscriptionService()

    convenience init(
        modelProvider: any WhisperModelProvider,
        modelsDirectory: URL,
        modelContext: ModelContext
    ) {
        self.init(
            modelProvider: modelProvider,
            modelsDirectory: modelsDirectory,
            modelContext: modelContext,
            pressureOperations: .shared
        )
    }

    init(
        modelProvider: any WhisperModelProvider,
        modelsDirectory: URL,
        modelContext: ModelContext,
        pressureOperations: RuntimePressureOperationCoordinator
    ) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
        self.pressureOperations = pressureOperations
        pressureOperations.registerResourceReleaseParticipant(
            id: pressureReleaseParticipantID,
            operation: { [weak self] in
                guard let self else { return true }
                return await self.performPressureResourceRelease()
            }
        )
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
                _ = await self?.pressureOperations.retryPendingRelease()
            }
        }
    }

    deinit {
        let pressureOperations = pressureOperations
        let pressureReleaseParticipantID = pressureReleaseParticipantID
        Task { @MainActor in
            pressureOperations.unregisterResourceReleaseParticipant(id: pressureReleaseParticipantID)
        }
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
        let coordinatesLocalRuntime = RuntimePressureOperationPolicy.coordinatesLocalRuntime(for: model.provider)
        if coordinatesLocalRuntime {
            guard await pressureOperations.beginOperation() else { throw CancellationError() }
        }
        defer {
            if coordinatesLocalRuntime {
                operationDidFinish()
            }
        }
        let service = service(for: model.provider)
        logger.debug(
            "Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)"
        )
        return try await service.transcribe(audioURL: audioURL, model: model, context: context.scoped(to: model))
    }

    func performPressureCoordinatedOperation(
        _ operation: () async throws -> Void
    ) async throws {
        guard await pressureOperations.beginOperation() else { throw CancellationError() }
        defer { operationDidFinish() }
        try await operation()
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
                StreamingTranscriptionSession(streamingService: streamingService, fallbackService: fallback),
                coordinatesLocalRuntime: RuntimePressureOperationPolicy.coordinatesLocalRuntime(for: model.provider)
            )
        } else {
            return managedSession(
                FileTranscriptionSession(service: service(for: model.provider)),
                coordinatesLocalRuntime: RuntimePressureOperationPolicy.coordinatesLocalRuntime(for: model.provider)
            )
        }
    }

    /// Whether the resolved transcription configuration should use real-time transcription.
    func shouldUseRealtimeTranscription(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.isRealtimeEnabled
    }

    func releaseUnboundLocalModelResources() async {
        guard !pressureOperations.hasActiveOperations,
            !pressureOperations.isReleasingResources,
            !pressureOperations.hasPendingRelease,
            !AudioDeviceManager.shared.isRecordingActive
        else {
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
        await pressureOperations.requestRegisteredResourceRelease(
            recordingIsActive: { AudioDeviceManager.shared.isRecordingActive }
        )
    }

    private func performPressureResourceRelease() async -> Bool {
        guard !Task.isCancelled else { return false }
        await modelProvider?.releaseAllResources()
        guard !Task.isCancelled else { return false }
        await fluidAudioTranscriptionService.releaseAllResourcesForPressure()
        guard !Task.isCancelled else { return false }
        _ = await sherpaOnnxTranscriptionService.releaseAllResources()
        guard !Task.isCancelled else { return false }
        await QwenMLXRuntime.shared.stop()
        guard !Task.isCancelled else { return false }
        logger.notice("Released all idle local model resources under memory pressure")
        return true
    }

    func cancelPressureResourceRelease() {
        pressureOperations.cancelPendingRelease()
    }

    private func managedSession(
        _ session: TranscriptionSession,
        coordinatesLocalRuntime: Bool
    ) -> TranscriptionSession {
        guard coordinatesLocalRuntime else { return session }
        return ResourceManagedTranscriptionSession(
            session: session,
            onPrepare: { [weak self] in
                guard let self else { return false }
                return await self.pressureOperations.beginOperation()
            },
            onFinish: { [weak self] in
                self?.operationDidFinish()
            }
        )
    }

    private func operationDidFinish() {
        pressureOperations.endOperation()
        Task { @MainActor [weak self] in
            await self?.releaseUnboundLocalModelResources()
        }
    }

    private func handleModeConfigurationsDidChange() async {
        await releaseUnboundLocalModelResources()
    }
}
