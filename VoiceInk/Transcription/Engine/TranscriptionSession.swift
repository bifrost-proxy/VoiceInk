import Foundation
import os

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> String

    /// Cancel the session and clean up resources.
    func cancel()

    /// Records audio discarded before it reached the session's streaming queue.
    func recordDroppedAudioChunks(_ count: Int)

    var performanceSnapshot: TranscriptionPerformanceSnapshot? { get }
}

extension TranscriptionSession {
    var performanceSnapshot: TranscriptionPerformanceSnapshot? { nil }

    func recordDroppedAudioChunks(_ count: Int) {}
}

@MainActor
final class ResourceManagedTranscriptionSession: TranscriptionSession {
    private let session: TranscriptionSession
    private var onFinish: (() -> Void)?

    init(session: TranscriptionSession, onFinish: @escaping () -> Void) {
        self.session = session
        self.onFinish = onFinish
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        do {
            return try await session.prepare(configuration: configuration)
        } catch {
            finish()
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        defer { finish() }
        return try await session.transcribe(audioURL: audioURL)
    }

    func cancel() {
        session.cancel()
        finish()
    }

    func recordDroppedAudioChunks(_ count: Int) {
        session.recordDroppedAudioChunks(count)
    }

    var performanceSnapshot: TranscriptionPerformanceSnapshot? {
        session.performanceSnapshot
    }

    private func finish() {
        let completion = onFinish
        onFinish = nil
        completion?()
    }

    deinit {
        let completion = onFinish
        if let completion {
            Task { @MainActor in completion() }
        }
    }
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        self.model = configuration.model
        self.context = configuration.requestContext.scoped(to: configuration.model)
        return nil
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cancel() {
        // No-op for file-based transcription
    }

    var performanceSnapshot: TranscriptionPerformanceSnapshot? {
        TranscriptionPerformanceSnapshot(executionMode: "batch")
    }
}

// MARK: - Streaming Session

/// Streaming session with automatic fallback to file-based upload on failure.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    enum Resolution: String {
        case streamingFinalized
        case batchFallbackRequested
        case batchFallbackAfterEmptyResult
        case batchFallbackAfterStreamingError
        case batchFallbackAfterStartupFailure
    }

    private let streamingService: StreamingTranscriptionService
    private let fallbackService: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private(set) var lastResolution: Resolution?
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private var fallbackDuration: TimeInterval?
    private var fallbackErrorDescription: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionSession")

    init(streamingService: StreamingTranscriptionService, fallbackService: TranscriptionService) {
        self.streamingService = streamingService
        self.fallbackService = fallbackService
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext.scoped(to: model)

        self.model = model
        self.context = context
        self.streamingFailed = false
        self.lastResolution = nil
        self.fallbackDuration = nil
        self.fallbackErrorDescription = nil
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        streamingService.prepareForStart()

        // Return callback immediately; WebSocket connects in background
        let service = streamingService
        let callback: (Data) -> Void = { [weak service] data in
            service?.sendAudioChunk(data)
        }

        startupTask?.cancel()
        let taskID = UUID()
        startupTaskID = taskID
        startupTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.startupTaskID == taskID {
                    self.startupTask = nil
                    self.startupTaskID = nil
                }
            }
            guard !Task.isCancelled else { return }

            do {
                let start = Date()
                try await self.streamingService.startStreaming(model: model, context: context)
                guard !Task.isCancelled else {
                    self.streamingService.cancel()
                    return
                }
                self.logger.notice(
                    "Streaming session connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s"
                )
            } catch is CancellationError {
                self.streamingService.cancel()
            } catch {
                guard !Task.isCancelled else { return }
                let desc = error.localizedDescription
                self.logger.error("❌ Failed to start streaming, will fall back to batch: \(desc, privacy: .public)")
                self.streamingFailed = true
            }
        }

        return callback
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        // A buffered local model may still be loading when the user releases the shortcut.
        // Let startup finish so queued audio can drain instead of treating it as disconnected.
        if let startupTask {
            let startedInTime = await StreamingAudioIntegrityPolicy.waitForCompletion(
                of: startupTask,
                timeout: StreamingAudioIntegrityPolicy.startupTimeout
            )
            if !startedInTime {
                logger.warning("Streaming startup exceeded the reliability deadline; retrying the complete audio file")
                streamingFailed = true
                startupTaskID = nil
                self.startupTask = nil
                streamingService.cancel()
            }
        }

        if !streamingFailed {
            do {
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let result = try await streamingService.stopAndFinalize()
                switch result {
                case .finalized(let text):
                    logger.notice(
                        "Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
                    )
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastResolution = .streamingFinalized
                        return text
                    }
                    lastResolution = .batchFallbackAfterEmptyResult
                    logger.warning("Streaming returned an empty transcript; retrying the complete audio file")
                case .requiresBatchFallback:
                    lastResolution = .batchFallbackRequested
                    logger.notice("Streaming provider requested full batch transcription")
                }
            } catch {
                lastResolution = .batchFallbackAfterStreamingError
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
                startupTask?.cancel()
                startupTask = nil
                startupTaskID = nil
                streamingService.cancel()
            }
        } else {
            lastResolution = .batchFallbackAfterStartupFailure
            startupTask?.cancel()
            startupTask = nil
            startupTaskID = nil
            streamingService.cancel()
        }

        let fallbackStart = Date()
        logger.notice(
            "Batch fallback started model=\(model.displayName, privacy: .public) resolution=\(self.lastResolution?.rawValue ?? "unknown", privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)"
        )
        do {
            let text = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
            fallbackDuration = Date().timeIntervalSince(fallbackStart)
            fallbackErrorDescription = nil
            logger.notice(
                "Batch fallback completed outcome=success elapsed=\(self.fallbackDuration ?? 0, format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
            )
            return text
        } catch {
            fallbackDuration = Date().timeIntervalSince(fallbackStart)
            fallbackErrorDescription = "\(String(reflecting: type(of: error))): \(error.localizedDescription)"
            logger.error(
                "Batch fallback completed outcome=failure elapsed=\(self.fallbackDuration ?? 0, format: .fixed(precision: 3), privacy: .public)s error=\(self.fallbackErrorDescription ?? error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    var performanceSnapshot: TranscriptionPerformanceSnapshot? {
        var snapshot = streamingService.performanceSnapshot
        if let model {
            switch TranscriptionRealtimeSupport.mode(for: model) {
            case .nativeStreaming:
                snapshot.executionMode = "nativeStreaming"
            case .slidingWindow:
                snapshot.executionMode = "slidingWindow"
            case .batchOnly:
                snapshot.executionMode = "batch"
            }
        }
        snapshot.streamingResolution = lastResolution?.rawValue
        snapshot.fallbackDuration = fallbackDuration
        snapshot.fallbackError = fallbackErrorDescription
        return snapshot
    }

    func cancel() {
        startupTask?.cancel()
        startupTask = nil
        startupTaskID = nil
        streamingService.cancel()
    }

    func recordDroppedAudioChunks(_ count: Int) {
        streamingService.recordDroppedAudioChunks(count)
    }
}
