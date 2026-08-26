import Foundation
import SwiftData
import os

private struct QueuedAudioChunk: Sendable {
    let data: Data
    let enqueuedAt: ContinuousClock.Instant
}

/// Sendable source that coalesces provider-specific packets before crossing an
/// actor boundary and enforces a queue limit expressed as audio duration.
private final class AudioChunkSource: @unchecked Sendable {
    let stream: AsyncStream<QueuedAudioChunk>
    private let continuation: AsyncStream<QueuedAudioChunk>.Continuation
    private let lock = NSLock()
    private var packetizer: DoubaoAudioPacketizer?
    private var queuedBytes = 0
    private var queuedChunks = 0
    private var maximumQueuedBytes: Int? = StreamingAudioIntegrityPolicy.maximumBacklogBytes
    private var maximumQueuedChunks: Int?
    private var pendingMaximumQueuedBytes: Int?
    private var isFinished = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: QueuedAudioChunk.self,
            bufferingPolicy: .unbounded
        )
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func configure(
        packetizeForDoubao: Bool,
        maximumBacklogBytes: Int?,
        maximumBacklogChunks: Int?
    ) {
        lock.withLock {
            precondition(queuedBytes == 0 && queuedChunks == 0 && !isFinished)
            packetizer = packetizeForDoubao ? DoubaoAudioPacketizer() : nil
            maximumQueuedBytes = maximumBacklogBytes
            maximumQueuedChunks = maximumBacklogChunks
            pendingMaximumQueuedBytes = nil
        }
    }

    func send(_ data: Data) -> (accepted: Bool, backlogBytes: Int) {
        lock.withLock {
            guard !isFinished else { return (false, queuedBytes) }
            let bufferedPacketBytes = packetizer?.bufferedByteCount ?? 0
            if let maximumQueuedBytes,
                queuedBytes + bufferedPacketBytes + data.count > maximumQueuedBytes
            {
                return (false, queuedBytes + bufferedPacketBytes)
            }
            if let maximumQueuedChunks, queuedChunks + 1 > maximumQueuedChunks {
                return (false, queuedBytes + bufferedPacketBytes)
            }

            let packets: [Data]
            if packetizer != nil {
                packets = packetizer!.append(data)
            } else {
                packets = [data]
            }
            for packet in packets {
                queuedBytes += packet.count
                queuedChunks += 1
                continuation.yield(QueuedAudioChunk(data: packet, enqueuedAt: .now))
            }
            return (true, queuedBytes + (packetizer?.bufferedByteCount ?? 0))
        }
    }

    /// Keep the larger startup allowance until the connection backlog drains
    /// below the steady-state cap. Reducing it immediately would drop newly
    /// recorded chunks while the send loop catches up after a valid handshake.
    func reduceMaximumBacklog(to maximumBacklogBytes: Int) {
        lock.withLock {
            let bufferedBytes = queuedBytes + (packetizer?.bufferedByteCount ?? 0)
            if bufferedBytes <= maximumBacklogBytes {
                maximumQueuedBytes = maximumBacklogBytes
                pendingMaximumQueuedBytes = nil
            } else {
                pendingMaximumQueuedBytes = maximumBacklogBytes
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            if var packetizer, let remainder = packetizer.flush() {
                queuedBytes += remainder.count
                queuedChunks += 1
                continuation.yield(QueuedAudioChunk(data: remainder, enqueuedAt: .now))
                self.packetizer = packetizer
            }
            continuation.finish()
        }
    }

    func didSend(_ chunk: QueuedAudioChunk) -> (backlogBytes: Int, sendLatency: Duration) {
        lock.withLock {
            queuedBytes = max(0, queuedBytes - chunk.data.count)
            queuedChunks = max(0, queuedChunks - 1)
            let bufferedBytes = queuedBytes + (packetizer?.bufferedByteCount ?? 0)
            if let pendingMaximumQueuedBytes, bufferedBytes <= pendingMaximumQueuedBytes {
                maximumQueuedBytes = pendingMaximumQueuedBytes
                self.pendingMaximumQueuedBytes = nil
            }
            return (queuedBytes, chunk.enqueuedAt.duration(to: .now))
        }
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
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

enum StreamingAudioIntegrityPolicy {
    static let legacyBufferCapacity = 2_048
    static let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size
    static let warningBacklogBytes = bytesPerSecond / 4
    static let maximumBacklogBytes = bytesPerSecond * 3 / 4
    static let startupTimeout: Duration = .seconds(4)
    static let drainTimeout: Duration = .seconds(1)
    static let commitTimeout: Duration = .seconds(4)
    static let finalTimeout: Duration = .seconds(4)
    static let disconnectTimeout: Duration = .milliseconds(500)

    static func startupBacklogBytes(deadline: Duration, attemptCount: Int) -> Int {
        let components = deadline.components
        let deadlineSeconds = max(
            0,
            Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
        let connectionAllowance = Int(ceil(deadlineSeconds * Double(max(1, attemptCount)) * Double(bytesPerSecond)))
        return max(maximumBacklogBytes, connectionAllowance + maximumBacklogBytes)
    }

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

struct StreamingDeadlines: Sendable {
    var startup: Duration = StreamingAudioIntegrityPolicy.startupTimeout
    var drain: Duration = StreamingAudioIntegrityPolicy.drainTimeout
    var commit: Duration = StreamingAudioIntegrityPolicy.commitTimeout
    var final: Duration = StreamingAudioIntegrityPolicy.finalTimeout
    var disconnect: Duration = StreamingAudioIntegrityPolicy.disconnectTimeout

    static let production = StreamingDeadlines()
    static let standardProduction = StreamingDeadlines(
        startup: .seconds(12),
        drain: .seconds(10),
        commit: .seconds(10),
        final: .seconds(10),
        disconnect: .seconds(3)
    )
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
    private var maximumBacklogBytes = 0
    private var maximumBacklogDuration: TimeInterval = 0
    private var maximumPacketSendDuration: TimeInterval = 0
    private var firstAudioAt: Date?
    private var backlogWarningReported = false

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
        maximumBacklogBytes = 0
        maximumBacklogDuration = 0
        maximumPacketSendDuration = 0
        firstAudioAt = nil
        backlogWarningReported = false
        lock.unlock()
    }

    func recordReceived(_ byteCount: Int) {
        lock.lock()
        if firstAudioAt == nil {
            firstAudioAt = Date()
        }
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

    func recordBacklog(byteCount: Int) -> Bool {
        lock.withLock {
            maximumBacklogBytes = max(maximumBacklogBytes, byteCount)
            maximumBacklogDuration = max(
                maximumBacklogDuration,
                Double(byteCount) / Double(StreamingAudioIntegrityPolicy.bytesPerSecond)
            )
            guard byteCount >= StreamingAudioIntegrityPolicy.warningBacklogBytes,
                !backlogWarningReported
            else {
                return false
            }
            backlogWarningReported = true
            return true
        }
    }

    func recordPacketSend(duration: Duration) {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        lock.withLock {
            maximumPacketSendDuration = max(maximumPacketSendDuration, seconds)
        }
    }

    func snapshot() -> (
        receivedChunks: Int,
        receivedBytes: Int,
        sentChunks: Int,
        sentBytes: Int,
        droppedChunks: Int,
        droppedBytes: Int,
        transportSendFailures: Int,
        transportFailedBytes: Int,
        maximumBacklogBytes: Int,
        maximumBacklogDuration: TimeInterval,
        maximumPacketSendDuration: TimeInterval,
        firstAudioAt: Date?
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
            transportFailedBytes,
            maximumBacklogBytes,
            maximumBacklogDuration,
            maximumPacketSendDuration,
            firstAudioAt
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

    func observedConcurrentAttemptCount() async -> Int? {
        await provider.observedConcurrentAttemptCount()
    }
}

/// Lifecycle states for a streaming transcription session.
enum StreamingState {
    case idle
    case connecting
    case streaming
    case draining
    case committing
    case recovering
    case cancelling
    case done
    case failed
    case cancelled
    case closed
}

enum StreamingTerminationReason: String, Sendable {
    case completed
    case stableSnapshot
    case committedSegments
    case connectTimeout
    case connectFailure
    case sendBacklog
    case drainTimeout
    case commitTimeout
    case commitFailure
    case missingFinal
    case sendFailure
    case receiveFailure
    case cancelled
    case disconnectTimeout
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
    private let configuredDeadlines: StreamingDeadlines?
    private var usesDoubaoDeadlines = false
    private var startupAttemptCount = 1
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
    private let sessionID = UUID()
    private var attemptID: UUID?
    private var firstServerEventAt: Date?
    private var lastServerEventAt: Date?
    private var commitSentAt: Date?
    private var terminationReason: StreamingTerminationReason?
    private var recoveryStrategy: String?
    private var cancelToSocketCloseDuration: TimeInterval?
    private var concurrentAttemptCount: Int?
    private var latestPreviewText = ""
    private var latestStableText = ""

    init(
        modelContext: ModelContext, fluidAudioService: FluidAudioTranscriptionService? = nil,
        sherpaOnnxService: SherpaOnnxTranscriptionService? = nil,
        onPartialTranscript: (@MainActor (String) -> Void)? = nil,
        providerFactory: ProviderFactory? = nil,
        customVocabulary: [String]? = nil,
        deadlines: StreamingDeadlines? = nil
    ) {
        self.customVocabulary = customVocabulary ?? TranscriptionVocabularyContext.uniqueTerms(from: modelContext)
        self.fluidAudioService = fluidAudioService
        self.sherpaOnnxService = sherpaOnnxService
        self.onPartialTranscript = onPartialTranscript
        self.providerFactory = providerFactory
        self.configuredDeadlines = deadlines
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
    var isActive: Bool {
        state == .streaming || state == .draining || state == .committing || state == .recovering
    }

    func beginCompleteFileStreamingRecovery() {
        guard state != .cancelling && state != .cancelled else { return }
        state = .recovering
        recoveryStrategy = "freshStreamingReplay"
    }

    func publishRecoveryPreview(_ text: String) {
        guard state == .recovering else { return }
        latestPreviewText = text
        onPartialTranscript?(text)
    }

    func finishCompleteFileStreamingRecovery(succeeded: Bool) {
        guard state == .recovering else { return }
        state = succeeded ? .done : .failed
    }

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
        result.sessionID = String(sessionID.uuidString.prefix(8))
        result.attemptID = attemptID.map { String($0.uuidString.prefix(8)) }
        result.firstAudioAt = counters.firstAudioAt
        result.firstServerEventAt = firstServerEventAt
        result.lastServerEventAt = lastServerEventAt
        result.commitSentAt = commitSentAt
        result.maxBacklogBytes = counters.maximumBacklogBytes
        result.maxBacklogDuration = counters.maximumBacklogDuration
        result.maxPacketSendDuration = counters.maximumPacketSendDuration
        result.terminationReason = terminationReason?.rawValue
        result.recoveryStrategy = recoveryStrategy
        result.cancelToSocketCloseDuration = cancelToSocketCloseDuration
        result.concurrentAttemptCount = concurrentAttemptCount
        return result
    }

    private var deadlines: StreamingDeadlines {
        configuredDeadlines ?? (usesDoubaoDeadlines ? .production : .standardProduction)
    }

    var startupDeadline: Duration {
        deadlines.startup * startupAttemptCount
            + deadlines.disconnect * max(0, startupAttemptCount - 1)
    }

    /// Resets session accounting before the recorder receives its audio
    /// callback. Local model loading is asynchronous, so doing this inside
    /// `startStreaming` could erase chunks already queued during cold start.
    func prepareForStart(model: (any TranscriptionModel)? = nil) {
        state = .connecting
        usesDoubaoDeadlines = model?.provider == .doubaoSpeech
        startupAttemptCount = model.map { shouldImmediatelyRetryConnection(for: $0) ? 2 : 1 } ?? 1
        chunkSource.configure(
            packetizeForDoubao: usesDoubaoDeadlines,
            maximumBacklogBytes: usesDoubaoDeadlines
                ? StreamingAudioIntegrityPolicy.startupBacklogBytes(
                    deadline: deadlines.startup,
                    attemptCount: startupAttemptCount
                )
                : nil,
            maximumBacklogChunks: usesDoubaoDeadlines
                ? nil
                : StreamingAudioIntegrityPolicy.legacyBufferCapacity
        )
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
        attemptID = nil
        firstServerEventAt = nil
        lastServerEventAt = nil
        commitSentAt = nil
        terminationReason = nil
        recoveryStrategy = nil
        cancelToSocketCloseDuration = nil
        concurrentAttemptCount = nil
        latestPreviewText = ""
        latestStableText = ""
    }

    /// Start a streaming transcription session for the given model.
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        let start = Date()
        if state != .connecting {
            prepareForStart(model: model)
        } else if configuredDeadlines == nil {
            usesDoubaoDeadlines = model.provider == .doubaoSpeech
        }

        let selectedLanguage = context.language ?? "auto"
        let maximumAttempts = shouldImmediatelyRetryConnection(for: model) ? 2 : 1

        for attempt in 1...maximumAttempts {
            let currentAttemptID = UUID()
            attemptID = currentAttemptID
            let provider = StreamingProviderTransport(
                provider: createProvider(for: model, context: context)
            )
            self.provider = provider

            logger.notice(
                "Streaming start requested model=\(model.displayName, privacy: .public) language=\(selectedLanguage, privacy: .public) attempt=\(attempt, privacy: .public)/\(maximumAttempts, privacy: .public)"
            )

            let connectFailure = StreamingOperationFailureBox()
            let connectTask = Task { @MainActor in
                do {
                    try await provider.connect(model: model, language: selectedLanguage)
                } catch {
                    connectFailure.record(error)
                }
            }
            let connectedInTime = await StreamingAudioIntegrityPolicy.waitForCompletion(
                of: connectTask,
                timeout: deadlines.startup
            )
            if !connectedInTime || connectFailure.error != nil {
                _ = await disconnectWithinDeadline(provider)
                self.provider = nil

                if state == .cancelling || state == .cancelled {
                    throw CancellationError()
                }
                if !connectedInTime {
                    terminationReason = .connectTimeout
                }
                guard attempt < maximumAttempts else {
                    if !connectedInTime {
                        throw StreamingTranscriptionError.timeout
                    }
                    terminationReason = .connectFailure
                    throw connectFailure.error ?? StreamingTranscriptionError.notConnected
                }

                logger.warning(
                    "Streaming connection attempt failed; reconnecting immediately model=\(model.displayName, privacy: .public) timedOut=\(!connectedInTime, privacy: .public) error=\(connectFailure.error?.localizedDescription ?? "deadline", privacy: .public)"
                )
                continue
            }

            connectionDuration = Date().timeIntervalSince(start)
            if terminationReason == .connectTimeout {
                terminationReason = nil
            }

            // If cancel() was called while we were awaiting the connection, tear down immediately.
            if state == .cancelling || state == .cancelled {
                _ = await disconnectWithinDeadline(provider)
                self.provider = nil
                throw CancellationError()
            }

            state = .streaming
            concurrentAttemptCount = await provider.observedConcurrentAttemptCount()
            if usesDoubaoDeadlines {
                chunkSource.reduceMaximumBacklog(to: StreamingAudioIntegrityPolicy.maximumBacklogBytes)
            }
            startSendLoop()
            await startEventConsumer(attemptID: currentAttemptID)

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
        let enqueueResult = chunkSource.send(data)
        if metrics.recordBacklog(byteCount: enqueueResult.backlogBytes) {
            Logger(
                subsystem: "com.prakashjoshipax.voiceink",
                category: "StreamingTranscriptionService"
            ).warning(
                "Streaming audio backlog crossed warning threshold bytes=\(enqueueResult.backlogBytes, privacy: .public)"
            )
        }
        if !enqueueResult.accepted {
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

        state = .draining
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
            if afterDrain.droppedChunks > 0 {
                terminationReason = .sendBacklog
            } else if afterDrain.transportSendFailures > 0 {
                terminationReason = .sendFailure
            } else if terminalReceiveErrorDescription != nil {
                terminationReason = .receiveFailure
            } else if !drainedInTime {
                terminationReason = .drainTimeout
            }
            recoveryStrategy = "completeFile"
            logger.warning(
                "Streaming audio integrity lost; retrying complete file droppedChunks=\(afterDrain.droppedChunks, privacy: .public) sendFailures=\(afterDrain.transportSendFailures, privacy: .public) receiveError=\(self.terminalReceiveErrorDescription != nil, privacy: .public) drainedInTime=\(drainedInTime, privacy: .public)"
            )
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }

        state = .committing

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
            timeout: deadlines.commit
        )
        if !committedInTime || commitFailure.error != nil {
            commitSignal?.finish()
            commitSignal = nil
            if let error = commitFailure.error {
                let description = error.localizedDescription
                logger.error("Failed to send commit: \(description, privacy: .public)")
            } else {
                logger.warning("Streaming commit exceeded the reliability deadline")
            }
            terminationReason = committedInTime ? .commitFailure : .commitTimeout
            recoveryStrategy = "completeFile"
            state = .failed
            await cleanupStreaming()
            if !committedInTime {
                throw StreamingTranscriptionError.timeout
            }
            throw StreamingTranscriptionError.connectionFailed(
                commitFailure.error?.localizedDescription ?? "Commit failed"
            )
        }
        commitSentAt = Date()

        // Wait for the server to acknowledge our commit (or timeout)
        let finalText = await waitForFinalCommit(signalStream: signalStream)
        if terminalReceiveErrorDescription != nil {
            terminationReason = .receiveFailure
            recoveryStrategy = "completeFile"
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
        if terminationReason == nil {
            terminationReason = .completed
        }
        await cleanupStreaming()

        return .finalized(text: finalText)
    }

    /// Cancels the streaming session without waiting for results.
    func cancel() {
        guard state != .cancelled && state != .closed else { return }
        state = .cancelling
        terminationReason = .cancelled
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

        let cancelStartedAt = Date()
        Task { @MainActor [self] in
            if let providerToDisconnect {
                let disconnected = await disconnectWithinDeadline(providerToDisconnect)
                if disconnected {
                    cancelToSocketCloseDuration = Date().timeIntervalSince(cancelStartedAt)
                }
            }
            state = .cancelled
        }

        committedSegments = []
        logger.notice("Streaming cancellation requested")
    }

    /// Stops a failed transport before complete-file recovery without clearing
    /// the presentation callback used by Doubao's streaming replay.
    func stopTransportForCompleteFileRecovery() async {
        guard state != .cancelling && state != .cancelled else { return }
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
        let providerToDisconnect = provider
        provider = nil
        if let providerToDisconnect {
            _ = await disconnectWithinDeadline(providerToDisconnect)
        }
        state = .failed
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
        let logger = logger

        sendTask = Task.detached {
            for await chunk in source.stream {
                do {
                    let sendStartedAt = ContinuousClock.now
                    try await provider?.sendAudioChunk(chunk.data)
                    metrics.recordPacketSend(duration: sendStartedAt.duration(to: .now))
                    metrics.recordSent(chunk.data.count)
                    let backlog = source.didSend(chunk)
                    _ = metrics.recordBacklog(byteCount: backlog.backlogBytes)
                } catch {
                    let desc = error.localizedDescription
                    metrics.recordTransportSendFailure(chunk.data.count)
                    _ = source.didSend(chunk)
                    logger.error("Failed to send audio chunk: \(desc, privacy: .public)")
                    source.finish()
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
                timeout: deadlines.drain
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
    private func startEventConsumer(attemptID consumerAttemptID: UUID) async {
        guard let provider = provider else { return }
        let events = await provider.transcriptionEvents

        eventConsumerTask = Task.detached { [weak self] in
            for await event in events {
                guard let self = self else { break }
                let isCurrentAttempt = await MainActor.run {
                    self.attemptID == consumerAttemptID
                        && self.state != .cancelling
                        && self.state != .cancelled
                        && self.state != .closed
                }
                guard isCurrentAttempt else { continue }
                switch event {
                case .committed(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self.firstServerEventAt = self.firstServerEventAt ?? Date()
                        self.lastServerEventAt = Date()
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
                            self.latestPreviewText = self.committedSegments.joined(separator: " ")
                            self.latestStableText = self.latestPreviewText
                        }
                        // Refresh the live preview so it keeps showing the full running transcript
                        // after a commit (instead of resetting to empty until the next partial).
                        if self.state == .streaming || self.state == .draining || self.state == .committing {
                            self.onPartialTranscript?(self.committedSegments.joined(separator: " "))
                        }
                        if self.state == .committing {
                            self.commitSignal?.yield()
                        }
                    }
                case .partial(let text):
                    await MainActor.run {
                        self.firstServerEventAt = self.firstServerEventAt ?? Date()
                        self.lastServerEventAt = Date()
                        if !self.firstPartialLogged {
                            self.firstPartialLogged = true
                            if let preparedAt = self.preparedAt {
                                self.firstPartialLatency = Date().timeIntervalSince(preparedAt)
                            }
                            self.logger.notice("Streaming first partial event chars=\(text.count, privacy: .public)")
                        }
                        self.latestPreviewText = text
                        if self.state == .streaming || self.state == .draining || self.state == .committing {
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
                        self.firstServerEventAt = self.firstServerEventAt ?? Date()
                        self.lastServerEventAt = Date()
                        if !self.firstPartialLogged {
                            self.firstPartialLogged = true
                            if let preparedAt = self.preparedAt {
                                self.firstPartialLatency = Date().timeIntervalSince(preparedAt)
                            }
                            self.logger.notice(
                                "Streaming first native snapshot chars=\(text.count, privacy: .public) stableChars=\(stableText.count, privacy: .public)"
                            )
                        }
                        self.latestPreviewText = text
                        self.latestStableText = stableText
                        if self.state == .streaming || self.state == .draining || self.state == .committing {
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

    /// Waits for an explicit final event. A fully stable snapshot is safe to
    /// use if the final frame is lost; ordinary partial text is never returned.
    private func waitForFinalCommit(signalStream: AsyncStream<Void>) async -> String {
        let finalTimeout = deadlines.final
        let receivedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in signalStream {
                    return true
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(for: finalTimeout)
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

        if !receivedInTime {
            let preview = latestPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stable = latestStableText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stable.isEmpty, stable == preview {
                terminationReason = .stableSnapshot
                logger.notice(
                    "Streaming final frame missing; using fully stable snapshot chars=\(stable.count, privacy: .public)"
                )
                return stable
            }

            if !committedSegments.isEmpty {
                terminationReason = .committedSegments
                logger.notice(
                    "Streaming final frame missing; using committed segments count=\(self.committedSegments.count, privacy: .public)"
                )
                return committedSegments.joined(separator: " ")
            }

            terminationReason = .missingFinal
            recoveryStrategy = "completeFile"
            logger.warning("Streaming final frame missing; retrying complete file")
        }

        return committedSegments.isEmpty ? "" : committedSegments.joined(separator: " ")
    }

    private func disconnectWithinDeadline(_ provider: StreamingProviderTransport) async -> Bool {
        let disconnectTask = Task.detached(priority: .utility) {
            await provider.disconnect()
        }
        let disconnected = await StreamingAudioIntegrityPolicy.waitForCompletion(
            of: disconnectTask,
            timeout: deadlines.disconnect
        )
        if !disconnected {
            logger.warning("Streaming disconnect exceeded the reliability deadline")
        }
        return disconnected
    }

    private func cleanupStreaming() async {
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
        if let provider {
            let disconnected = await disconnectWithinDeadline(provider)
            if !disconnected {
                if terminationReason == nil || terminationReason == .completed {
                    terminationReason = .disconnectTimeout
                }
            }
        }
        provider = nil
        state = .closed
        committedSegments = []
    }
}
