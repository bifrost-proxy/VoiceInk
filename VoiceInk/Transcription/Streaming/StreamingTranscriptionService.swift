import Foundation
import SwiftData
import os

/// Sendable source that bridges audio chunks from any thread into an AsyncStream.
private final class AudioChunkSource: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(StreamingAudioIntegrityPolicy.bufferCapacity)
        )
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func send(_ data: Data) -> Bool {
        switch continuation.yield(data) {
        case .enqueued(_):
            return true
        case .dropped(_), .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func finish() {
        continuation.finish()
    }
}

private actor StreamingTaskCompletionRace {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}

private final class StreamingOperationFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDescription: String?

    var description: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedDescription
    }

    func record(_ error: Error) {
        lock.lock()
        storedDescription = error.localizedDescription
        lock.unlock()
    }
}

enum StreamingAudioIntegrityPolicy {
    static let bufferCapacity = 2_048
    static let startupTimeout: Duration = .seconds(12)
    static let drainTimeout: Duration = .seconds(10)
    static let commitTimeout: Duration = .seconds(10)
    static let disconnectTimeout: Duration = .seconds(3)

    static func requiresBatchFallback(
        droppedChunks: Int,
        transportSendFailures: Int,
        hasTerminalReceiveError: Bool,
        drainedInTime: Bool
    ) -> Bool {
        droppedChunks > 0
            || transportSendFailures > 0
            || hasTerminalReceiveError
            || !drainedInTime
    }

    /// Waits for an unstructured task without making a non-cooperative provider
    /// a permanent blocker. The underlying task is cancelled on timeout; the
    /// caller can immediately recover from the complete recorded WAV file.
    static func waitForCompletion(
        of task: Task<Void, Never>,
        timeout: Duration
    ) async -> Bool {
        let race = StreamingTaskCompletionRace()
        let completionWatcher = Task.detached {
            await task.value
            await race.resolve(true)
        }
        let timeoutWatcher = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: timeout)
                await race.resolve(false)
            } catch {
                // The operation completed before the deadline.
            }
        }

        let completed = await race.wait()
        if !completed {
            task.cancel()
        }
        completionWatcher.cancel()
        timeoutWatcher.cancel()
        return completed
    }
}

private final class StreamingMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedChunks = 0
    private var receivedBytes = 0
    private var sentChunks = 0
    private var sentBytes = 0
    private var droppedChunks = 0
    private var droppedBytes = 0
    private var transportSendFailures = 0
    private var transportFailedBytes = 0

    func reset() {
        lock.lock()
        receivedChunks = 0
        receivedBytes = 0
        sentChunks = 0
        sentBytes = 0
        droppedChunks = 0
        droppedBytes = 0
        transportSendFailures = 0
        transportFailedBytes = 0
        lock.unlock()
    }

    func recordReceived(_ byteCount: Int) {
        lock.lock()
        receivedChunks += 1
        receivedBytes += byteCount
        lock.unlock()
    }

    func recordSent(_ byteCount: Int) {
        lock.lock()
        sentChunks += 1
        sentBytes += byteCount
        lock.unlock()
    }

    func recordDropped(_ byteCount: Int) {
        lock.lock()
        droppedChunks += 1
        droppedBytes += byteCount
        lock.unlock()
    }

    func recordDroppedChunks(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        droppedChunks += count
        lock.unlock()
    }

    func recordTransportSendFailure(_ byteCount: Int) {
        lock.lock()
        transportSendFailures += 1
        transportFailedBytes += byteCount
        lock.unlock()
    }

    func snapshot() -> (
        receivedChunks: Int,
        receivedBytes: Int,
        sentChunks: Int,
        sentBytes: Int,
        droppedChunks: Int,
        droppedBytes: Int,
        transportSendFailures: Int,
        transportFailedBytes: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            receivedChunks,
            receivedBytes,
            sentChunks,
            sentBytes,
            droppedChunks,
            droppedBytes,
            transportSendFailures,
            transportFailedBytes
        )
    }
}

/// Owns one provider for one recording and serializes all transport work away
/// from the main actor. A new transport is created for every recording; it is
/// never pooled or reused across sessions.
actor StreamingProviderTransport {
    private let provider: any StreamingTranscriptionProvider

    init(provider: any StreamingTranscriptionProvider) {
        self.provider = provider
    }

    var stopDisposition: StreamingStopDisposition {
        provider.stopDisposition
    }

    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> {
        provider.transcriptionEvents
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        try await provider.connect(model: model, language: language)
    }

    func sendAudioChunk(_ data: Data) async throws {
        try await provider.sendAudioChunk(data)
    }

    func commit() async throws {
        try await provider.commit()
    }

    func disconnect() async {
        await provider.disconnect()
    }
}

/// Lifecycle states for a streaming transcription session.
enum StreamingState {
    case idle
    case connecting
    case streaming
    case committing
    case done
    case failed
    case cancelled
}

enum StreamingStopResult {
    case finalized(text: String)
    case requiresBatchFallback
}

/// Manages a streaming transcription lifecycle: buffers audio chunks, sends them to the provider, and collects the final text.
@MainActor
class StreamingTranscriptionService {

    typealias ProviderFactory = (
        _ model: any TranscriptionModel,
        _ context: TranscriptionRequestContext,
        _ customVocabulary: [String]
    ) -> any StreamingTranscriptionProvider

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionService")
    private var provider: StreamingProviderTransport?
    private var sendTask: Task<Void, Never>?
    private var eventConsumerTask: Task<Void, Never>?
    private let chunkSource = AudioChunkSource()
    private var state: StreamingState = .idle
    private var committedSegments: [String] = []
    private let customVocabulary: [String]
    private let fluidAudioService: FluidAudioTranscriptionService?
    private let sherpaOnnxService: SherpaOnnxTranscriptionService?
    private let providerFactory: ProviderFactory?
    private var onPartialTranscript: (@MainActor (String) -> Void)?
    private let metrics = StreamingMetrics()
    private var stopStartedAt: Date?
    private var firstPartialLogged = false
    private var firstCommitLogged = false
    private var preparedAt: Date?
    private var connectionDuration: TimeInterval?
    private var firstPartialLatency: TimeInterval?
    private var firstCommitLatency: TimeInterval?
    private var drainDuration: TimeInterval?
    private var finalizationDuration: TimeInterval?
    private var terminalReceiveErrorDescription: String?

    init(
        modelContext: ModelContext, fluidAudioService: FluidAudioTranscriptionService? = nil,
        sherpaOnnxService: SherpaOnnxTranscriptionService? = nil,
        onPartialTranscript: (@MainActor (String) -> Void)? = nil,
        providerFactory: ProviderFactory? = nil,
        customVocabulary: [String]? = nil
    ) {
        self.customVocabulary = customVocabulary ?? TranscriptionVocabularyContext.uniqueTerms(from: modelContext)
        self.fluidAudioService = fluidAudioService
        self.sherpaOnnxService = sherpaOnnxService
        self.onPartialTranscript = onPartialTranscript
        self.providerFactory = providerFactory
    }

    deinit {
        onPartialTranscript = nil
        sendTask?.cancel()
        eventConsumerTask?.cancel()
        chunkSource.finish()
        commitSignal?.finish()
    }

    /// Signal used to notify `waitForFinalCommit` when a new committed segment arrives.
    private var commitSignal: AsyncStream<Void>.Continuation?

    /// Whether the streaming connection is fully established and actively sending.
    var isActive: Bool { state == .streaming || state == .committing }

    var performanceSnapshot: TranscriptionPerformanceSnapshot {
        var result = TranscriptionPerformanceSnapshot(executionMode: "streaming")
        let counters = metrics.snapshot()
        result.connectionDuration = connectionDuration
        result.firstPartialLatency = firstPartialLatency
        result.firstCommitLatency = firstCommitLatency
        result.drainDuration = drainDuration
        result.finalizationDuration = finalizationDuration
        result.receivedChunks = counters.receivedChunks
        result.receivedBytes = counters.receivedBytes
        result.sentChunks = counters.sentChunks
        result.sentBytes = counters.sentBytes
        result.droppedChunks = counters.droppedChunks
        result.droppedBytes = counters.droppedBytes
        result.transportSendFailures = counters.transportSendFailures
        result.transportFailedBytes = counters.transportFailedBytes
        result.terminalReceiveError = terminalReceiveErrorDescription
        return result
    }

    /// Resets session accounting before the recorder receives its audio
    /// callback. Local model loading is asynchronous, so doing this inside
    /// `startStreaming` could erase chunks already queued during cold start.
    func prepareForStart() {
        state = .connecting
        committedSegments = []
        metrics.reset()
        firstPartialLogged = false
        firstCommitLogged = false
        stopStartedAt = nil
        preparedAt = Date()
        connectionDuration = nil
        firstPartialLatency = nil
        firstCommitLatency = nil
        drainDuration = nil
        finalizationDuration = nil
        terminalReceiveErrorDescription = nil
    }

    /// Start a streaming transcription session for the given model.
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        let start = Date()
        if state != .connecting {
            prepareForStart()
        }

        let selectedLanguage = context.language ?? "auto"
        let maximumAttempts = shouldImmediatelyRetryConnection(for: model) ? 2 : 1

        for attempt in 1...maximumAttempts {
            let provider = StreamingProviderTransport(
                provider: createProvider(for: model, context: context)
            )
            self.provider = provider

            logger.notice(
                "Streaming start requested model=\(model.displayName, privacy: .public) language=\(selectedLanguage, privacy: .public) attempt=\(attempt, privacy: .public)/\(maximumAttempts, privacy: .public)"
            )

            do {
                try await provider.connect(model: model, language: selectedLanguage)
            } catch {
                await provider.disconnect()
                self.provider = nil

                if state == .cancelled {
                    throw CancellationError()
                }
                guard attempt < maximumAttempts else {
                    throw error
                }

                logger.warning(
                    "Streaming connection attempt failed; reconnecting immediately model=\(model.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            connectionDuration = Date().timeIntervalSince(start)

            // If cancel() was called while we were awaiting the connection, tear down immediately.
            if state == .cancelled {
                await provider.disconnect()
                self.provider = nil
                return
            }

            state = .streaming
            startSendLoop()
            await startEventConsumer()

            logger.notice(
                "Streaming connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s attempt=\(attempt, privacy: .public)"
            )
            return
        }
    }

    private func shouldImmediatelyRetryConnection(for model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .aliyunQwen, .doubaoSpeech:
            true
        default:
            false
        }
    }

    /// Buffers an audio chunk for sending. Safe to call from the recorder processing queue.
    nonisolated func sendAudioChunk(_ data: Data) {
        metrics.recordReceived(data.count)
        if !chunkSource.send(data) {
            metrics.recordDropped(data.count)
        }
    }

    /// Includes chunks lost by the pre-session gate in the same integrity
    /// decision used for the streaming queue. Their bytes are unavailable, but
    /// any positive count is enough to require the complete-file fallback.
    nonisolated func recordDroppedAudioChunks(_ count: Int) {
        metrics.recordDroppedChunks(count)
    }

    /// Stops streaming and follows the provider's requested finalization path.
    func stopAndFinalize() async throws -> StreamingStopResult {
        guard let provider = provider, state == .streaming else {
            throw StreamingTranscriptionError.notConnected
        }

        if await provider.stopDisposition == .useBatchFallback {
            logger.notice("Streaming provider requested full batch fallback")
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }

        state = .committing
        stopStartedAt = Date()
        let beforeDrain = metrics.snapshot()
        logger.notice(
            "Streaming stop requested receivedChunks=\(beforeDrain.receivedChunks, privacy: .public) sentChunks=\(beforeDrain.sentChunks, privacy: .public) droppedChunks=\(beforeDrain.droppedChunks, privacy: .public) receivedBytes=\(beforeDrain.receivedBytes, privacy: .public) sentBytes=\(beforeDrain.sentBytes, privacy: .public) droppedBytes=\(beforeDrain.droppedBytes, privacy: .public)"
        )

        // Finish the chunk source so the send loop drains remaining chunks and exits naturally.
        let drainedInTime = await drainRemainingChunks()
        let afterDrain = metrics.snapshot()
        if StreamingAudioIntegrityPolicy.requiresBatchFallback(
            droppedChunks: afterDrain.droppedChunks,
            transportSendFailures: afterDrain.transportSendFailures,
            hasTerminalReceiveError: terminalReceiveErrorDescription != nil,
            drainedInTime: drainedInTime
        ) {
            logger.warning(
                "Streaming audio integrity lost; retrying complete file droppedChunks=\(afterDrain.droppedChunks, privacy: .public) sendFailures=\(afterDrain.transportSendFailures, privacy: .public) receiveError=\(self.terminalReceiveErrorDescription != nil, privacy: .public) drainedInTime=\(drainedInTime, privacy: .public)"
            )
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }

        // Set up the commit signal BEFORE sending commit to avoid a race with the response.
        let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
        self.commitSignal = signalContinuation

        // A provider is not allowed to keep the pipeline stuck forever while
        // committing. A timeout falls through to the session's full-file retry.
        let commitFailure = StreamingOperationFailureBox()
        let commitTask = Task.detached(priority: .userInitiated) {
            do {
                try await provider.commit()
            } catch {
                commitFailure.record(error)
            }
        }
        let committedInTime = await StreamingAudioIntegrityPolicy.waitForCompletion(
            of: commitTask,
            timeout: StreamingAudioIntegrityPolicy.commitTimeout
        )
        if !committedInTime || commitFailure.description != nil {
            commitSignal?.finish()
            commitSignal = nil
            if let description = commitFailure.description {
                logger.error("Failed to send commit: \(description, privacy: .public)")
            } else {
                logger.warning("Streaming commit exceeded the reliability deadline")
            }
            state = .failed
            await cleanupStreaming()
            if !committedInTime {
                throw StreamingTranscriptionError.timeout
            }
            throw StreamingTranscriptionError.connectionFailed(
                commitFailure.description ?? "Commit failed"
            )
        }

        // Wait for the server to acknowledge our commit (or timeout)
        let finalText = await waitForFinalCommit(signalStream: signalStream)
        if terminalReceiveErrorDescription != nil {
            logger.warning("Streaming receive failed during commit; retrying complete file")
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }
        if let stopStartedAt {
            finalizationDuration = Date().timeIntervalSince(stopStartedAt)
            logger.notice(
                "Streaming stop completed elapsed=\(Date().timeIntervalSince(stopStartedAt), format: .fixed(precision: 3), privacy: .public)s finalChars=\(finalText.count, privacy: .public)"
            )
        }

        state = .done
        await cleanupStreaming()

        return .finalized(text: finalText)
    }

    /// Cancels the streaming session without waiting for results.
    func cancel() {
        state = .cancelled
        onPartialTranscript = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()

        // Clean up commit signal if waiting
        commitSignal?.finish()
        commitSignal = nil

        let providerToDisconnect = provider
        provider = nil

        Task {
            await providerToDisconnect?.disconnect()
        }

        committedSegments = []
        logger.notice("Streaming cancelled")
    }

    // MARK: - Private

    private func createProvider(
        for model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) -> StreamingTranscriptionProvider {
        if let providerFactory {
            return providerFactory(model, context, customVocabulary)
        }
        if model.provider == .qwenMlx {
            return QwenMLXStreamingProvider(context: context.prompt)
        }
        if model.provider == .aliyunQwen {
            return AliyunQwenStreamingProvider(
                customVocabulary: customVocabulary,
                recognitionContext: context.speechRecognitionContext
            )
        }
        if model.provider == .doubaoSpeech {
            return DoubaoStreamingProvider(
                customVocabulary: customVocabulary,
                recognitionContext: context.speechRecognitionContext
            )
        }

        if model.provider == .fluidAudio {
            if FluidAudioModelManager.isNemotronModel(named: model.name) {
                return FluidAudioNemotronStreamingProvider()
            }

            if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
                return FluidAudioUnifiedStreamingProvider()
            }

            guard let fluidAudioService else {
                fatalError(
                    "FluidAudioTranscriptionService required for FluidAudio streaming. Ensure it is passed to StreamingTranscriptionService."
                )
            }

            if FluidAudioModelManager.isSenseVoiceModel(named: model.name)
                || FluidAudioModelManager.isParaformerZhModel(named: model.name)
                || FluidAudioModelManager.isParakeetCtcZhCnModel(named: model.name)
            {
                let configuration: BufferedOnDeviceStreamingProvider.Configuration =
                    FluidAudioModelManager.isParakeetCtcZhCnModel(named: model.name)
                    ? .fastPreview
                    : .default
                return BufferedOnDeviceStreamingProvider(
                    backend: .funASR(fluidAudioService),
                    configuration: configuration
                )
            }
            return FluidAudioStreamingProvider(fluidAudioService: fluidAudioService)
        }
        if model.provider == .sherpaOnnx {
            guard let sherpaOnnxService else {
                fatalError(
                    "SherpaOnnxTranscriptionService required for sherpa-onnx streaming previews."
                )
            }
            return BufferedOnDeviceStreamingProvider(
                backend: .qwen3ASR(sherpaOnnxService),
                configuration: .responsivePreview
            )
        }
        guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider),
            let streamingProvider = cloudProvider.makeStreamingProvider(customVocabulary: customVocabulary)
        else {
            fatalError(
                "Unsupported streaming provider: \(model.provider). Check shouldUseRealtimeTranscription() before calling startStreaming()."
            )
        }
        return streamingProvider
    }

    /// Consumes audio chunks from the AsyncStream and sends them to the provider.
    private func startSendLoop() {
        let source = chunkSource
        let provider = provider
        let metrics = metrics

        sendTask = Task.detached { [weak self] in
            for await chunk in source.stream {
                do {
                    try await provider?.sendAudioChunk(chunk)
                    metrics.recordSent(chunk.count)
                } catch {
                    let desc = error.localizedDescription
                    metrics.recordTransportSendFailure(chunk.count)
                    await MainActor.run {
                        self?.logger.error("Failed to send audio chunk: \(desc, privacy: .public)")
                        self?.chunkSource.finish()
                    }
                    break
                }
            }
        }
    }

    /// Finishes the chunk source and waits for the send loop to process all remaining buffered chunks.
    private func drainRemainingChunks() async -> Bool {
        let start = Date()
        chunkSource.finish()
        let completed: Bool
        if let sendTask {
            completed = await StreamingAudioIntegrityPolicy.waitForCompletion(
                of: sendTask,
                timeout: StreamingAudioIntegrityPolicy.drainTimeout
            )
        } else {
            completed = true
        }
        sendTask = nil
        let snapshot = metrics.snapshot()
        drainDuration = Date().timeIntervalSince(start)
        logger.notice(
            "Streaming drain finished elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s receivedChunks=\(snapshot.receivedChunks, privacy: .public) sentChunks=\(snapshot.sentChunks, privacy: .public) droppedChunks=\(snapshot.droppedChunks, privacy: .public) receivedBytes=\(snapshot.receivedBytes, privacy: .public) sentBytes=\(snapshot.sentBytes, privacy: .public) droppedBytes=\(snapshot.droppedBytes, privacy: .public)"
        )
        if !completed {
            logger.warning("Streaming audio drain exceeded the reliability deadline")
        }
        return completed
    }

    /// Consumes transcription events throughout the session, accumulating committed segments.
    private func startEventConsumer() async {
        guard let provider = provider else { return }
        let events = await provider.transcriptionEvents

        eventConsumerTask = Task.detached { [weak self] in
            for await event in events {
                guard let self = self else { break }
                switch event {
                case .committed(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if !self.firstCommitLogged {
                            self.firstCommitLogged = true
                            if let preparedAt = self.preparedAt {
                                self.firstCommitLatency = Date().timeIntervalSince(preparedAt)
                            }
                            let elapsed = self.stopStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                            self.logger.notice(
                                "Streaming first committed event chars=\(trimmed.count, privacy: .public) stopElapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s"
                            )
                        }
                        if !trimmed.isEmpty {
                            self.committedSegments.append(trimmed)
                        }
                        // Refresh the live preview so it keeps showing the full running transcript
                        // after a commit (instead of resetting to empty until the next partial).
                        if self.state == .streaming {
                            self.onPartialTranscript?(self.committedSegments.joined(separator: " "))
                        }
                        if self.state == .committing {
                            self.commitSignal?.yield()
                        }
                    }
                case .partial(let text):
                    await MainActor.run {
                        if !self.firstPartialLogged {
                            self.firstPartialLogged = true
                            if let preparedAt = self.preparedAt {
                                self.firstPartialLatency = Date().timeIntervalSince(preparedAt)
                            }
                            self.logger.notice("Streaming first partial event chars=\(text.count, privacy: .public)")
                        }
                        if self.state == .streaming {
                            let prefix = self.committedSegments.joined(separator: " ")
                            let display: String
                            if prefix.isEmpty {
                                display = text
                            } else if text.hasPrefix(prefix) || text.hasPrefix(prefix + " ") {
                                // Provider already sends cumulative partials (e.g. FluidAudio fullText).
                                display = text
                            } else {
                                display = prefix + " " + text
                            }
                            self.onPartialTranscript?(display)
                        }
                    }
                case .snapshot(let text, let stableText):
                    await MainActor.run {
                        if !self.firstPartialLogged {
                            self.firstPartialLogged = true
                            if let preparedAt = self.preparedAt {
                                self.firstPartialLatency = Date().timeIntervalSince(preparedAt)
                            }
                            self.logger.notice(
                                "Streaming first native snapshot chars=\(text.count, privacy: .public) stableChars=\(stableText.count, privacy: .public)"
                            )
                        }
                        if self.state == .streaming {
                            self.onPartialTranscript?(text)
                        }
                    }
                case .sessionStarted:
                    break
                case .error(let error):
                    await MainActor.run {
                        self.logger.error("Streaming event error: \(error, privacy: .public)")
                        if self.terminalReceiveErrorDescription == nil {
                            self.terminalReceiveErrorDescription = error.localizedDescription
                        }
                        self.chunkSource.finish()
                        self.sendTask?.cancel()
                        self.commitSignal?.finish()
                    }
                }
            }
        }
    }

    /// Waits for the server to acknowledge our explicit commit, with a 10-second timeout.
    private func waitForFinalCommit(signalStream: AsyncStream<Void>) async -> String {
        // Race: wait for commit acknowledgment vs timeout
        let receivedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in signalStream {
                    return true
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        logger.notice(
            "Streaming final wait finished received=\(receivedInTime, privacy: .public) segments=\(self.committedSegments.count, privacy: .public)"
        )

        // Clean up the signal
        commitSignal?.finish()
        commitSignal = nil

        if !receivedInTime && committedSegments.isEmpty {
            logger.warning("No transcript received from streaming")
        }

        return committedSegments.isEmpty ? "" : committedSegments.joined(separator: " ")
    }

    private func cleanupStreaming() async {
        onPartialTranscript = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
        if let provider {
            let disconnectTask = Task.detached(priority: .utility) {
                await provider.disconnect()
            }
            let disconnected = await StreamingAudioIntegrityPolicy.waitForCompletion(
                of: disconnectTask,
                timeout: StreamingAudioIntegrityPolicy.disconnectTimeout
            )
            if !disconnected {
                logger.warning("Streaming disconnect exceeded the reliability deadline")
            }
        }
        provider = nil
        state = .idle
        committedSegments = []
    }
}
