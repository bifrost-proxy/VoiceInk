import Foundation
import SwiftData
import Testing

@testable import VoiceInk

struct StreamingIntegrityTests {
    @MainActor
    @Test func audioSendFailureRejectsStreamingResultWithoutCommit() async throws {
        let provider = IntegrityProbeProvider(failSendAt: 6)
        let service = try makeService(provider: provider)
        let model = IntegrityTestModel()

        service.prepareForStart()
        try await service.startStreaming(
            model: model,
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )

        for index in 0..<8 {
            service.sendAudioChunk(Data(repeating: UInt8(index), count: 320))
        }

        let result = try await service.stopAndFinalize()
        guard case .requiresBatchFallback = result else {
            Issue.record("A known transport send failure must reject the streaming transcript")
            return
        }

        let snapshot = provider.snapshot()
        #expect(snapshot.sendAttempts == 6)
        #expect(snapshot.commitCount == 0)
        #expect(service.performanceSnapshot.transportSendFailures == 1)
        #expect(service.performanceSnapshot.transportFailedBytes == 320)
    }

    @MainActor
    @Test func terminalReceiveErrorRejectsStreamingResultWithoutCommit() async throws {
        let provider = IntegrityProbeProvider()
        let service = try makeService(provider: provider)
        let model = IntegrityTestModel()

        service.prepareForStart()
        try await service.startStreaming(
            model: model,
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        provider.emit(error: IntegrityTestError.receiveFailed)

        for _ in 0..<20 where service.performanceSnapshot.terminalReceiveError == nil {
            await Task.yield()
        }

        let result = try await service.stopAndFinalize()
        guard case .requiresBatchFallback = result else {
            Issue.record("A terminal receive error must reject the streaming transcript")
            return
        }

        #expect(provider.snapshot().commitCount == 0)
        #expect(service.performanceSnapshot.terminalReceiveError != nil)
        #expect(service.performanceSnapshot.firstServerEventAt == nil)
        #expect(service.performanceSnapshot.lastServerEventAt == nil)
    }

    @MainActor
    @Test func terminalReceiveErrorDuringCommitRejectsStreamingResult() async throws {
        let provider = IntegrityProbeProvider(errorOnCommit: true)
        let service = try makeService(provider: provider)

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        service.sendAudioChunk(Data(repeating: 0x7f, count: 320))

        let result = try await service.stopAndFinalize()
        guard case .requiresBatchFallback = result else {
            Issue.record("A receive error racing with commit must reject the streaming transcript")
            return
        }

        #expect(provider.snapshot().commitCount == 1)
        #expect(service.performanceSnapshot.terminalReceiveError != nil)
    }

    @MainActor
    @Test func cloudConnectionFailureReconnectsBeforeBufferedAudioIsDrained() async throws {
        let failedProvider = ReconnectProbeProvider(connectionError: ReconnectTestError.connectionFailed)
        let connectedProvider = ReconnectProbeProvider()
        let providerSequence = ReconnectProviderSequence([failedProvider, connectedProvider])
        let container = try ModelContainer(
            for: VocabularyWord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = StreamingTranscriptionService(
            modelContext: ModelContext(container),
            providerFactory: { _, _, _ in providerSequence.next() }
        )
        let bufferedAudio = Data(repeating: 0x42, count: 640)

        service.prepareForStart()
        service.sendAudioChunk(bufferedAudio)
        try await service.startStreaming(
            model: IntegrityTestModel(provider: .aliyunQwen),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )

        let result = try await service.stopAndFinalize()
        guard case .finalized(let text) = result else {
            Issue.record("The immediate reconnect should preserve the streaming result")
            return
        }

        #expect(text == "reconnected")
        #expect(failedProvider.snapshot().connectCount == 1)
        #expect(failedProvider.snapshot().disconnectCount == 1)
        #expect(failedProvider.snapshot().sentAudio.isEmpty)
        #expect(connectedProvider.snapshot().connectCount == 1)
        #expect(connectedProvider.snapshot().sentAudio == [bufferedAudio])
        #expect(connectedProvider.snapshot().commitCount == 1)
        #expect(service.performanceSnapshot.receivedChunks == 1)
        #expect(service.performanceSnapshot.sentChunks == 1)
    }

    @MainActor
    @Test func cloudConnectionFailureFallsThroughAfterOneImmediateRetry() async throws {
        let firstProvider = ReconnectProbeProvider(connectionError: ReconnectTestError.connectionFailed)
        let secondProvider = ReconnectProbeProvider(connectionError: ReconnectTestError.connectionFailed)
        let providerSequence = ReconnectProviderSequence([firstProvider, secondProvider])
        let container = try ModelContainer(
            for: VocabularyWord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = StreamingTranscriptionService(
            modelContext: ModelContext(container),
            providerFactory: { _, _, _ in providerSequence.next() }
        )

        service.prepareForStart()
        do {
            try await service.startStreaming(
                model: IntegrityTestModel(provider: .doubaoSpeech),
                context: TranscriptionRequestContext(language: "auto", prompt: nil)
            )
            Issue.record("Two failed cloud connections should preserve the full-file fallback path")
        } catch ReconnectTestError.connectionFailed {
            // Expected: StreamingTranscriptionSession will now use the existing full-file fallback.
        }

        #expect(firstProvider.snapshot().connectCount == 1)
        #expect(firstProvider.snapshot().disconnectCount == 1)
        #expect(secondProvider.snapshot().connectCount == 1)
        #expect(secondProvider.snapshot().disconnectCount == 1)
        #expect(providerSequence.requestCount == 2)
        #expect(
            service.performanceSnapshot.terminationReason
                == StreamingTerminationReason.connectFailure.rawValue
        )
    }

    @MainActor
    @Test func fullyStableSnapshotIsSafeWhenFinalFrameIsMissing() async throws {
        let provider = IntegrityProbeProvider(suppressCommitEvent: true)
        let service = try makeService(
            provider: provider,
            deadlines: StreamingDeadlines(final: .milliseconds(20))
        )

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        provider.emitSnapshot(text: "stable result", stableText: "stable result")
        for _ in 0..<20 where service.performanceSnapshot.firstServerEventAt == nil {
            await Task.yield()
        }

        let result = try await service.stopAndFinalize()
        guard case .finalized(let text) = result else {
            Issue.record("A fully stable snapshot should be usable after a lost final frame")
            return
        }
        #expect(text == "stable result")
        #expect(service.performanceSnapshot.terminationReason == StreamingTerminationReason.stableSnapshot.rawValue)
    }

    @MainActor
    @Test func ordinaryPartialIsNeverPromotedWhenFinalFrameIsMissing() async throws {
        let provider = IntegrityProbeProvider(suppressCommitEvent: true)
        let service = try makeService(
            provider: provider,
            deadlines: StreamingDeadlines(final: .milliseconds(20))
        )

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        provider.emitSnapshot(text: "unsafe partial", stableText: "safe")
        for _ in 0..<20 where service.performanceSnapshot.firstServerEventAt == nil {
            await Task.yield()
        }

        let result = try await service.stopAndFinalize()
        guard case .finalized(let text) = result else {
            Issue.record("Missing final should return an empty streaming result for complete-file recovery")
            return
        }
        #expect(text.isEmpty)
        #expect(service.performanceSnapshot.terminationReason == StreamingTerminationReason.missingFinal.rawValue)
    }

    @MainActor
    @Test func audioDurationBacklogLimitRejectsRealtimePathWithoutLosingWAVRecovery() async throws {
        let provider = IntegrityProbeProvider(sendDelay: .milliseconds(100))
        let service = try makeService(
            provider: provider,
            deadlines: StreamingDeadlines(drain: .milliseconds(20))
        )

        service.prepareForStart(model: IntegrityTestModel(provider: .doubaoSpeech))
        try await service.startStreaming(
            model: IntegrityTestModel(provider: .doubaoSpeech),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        for _ in 0..<100 {
            service.sendAudioChunk(Data(repeating: 0x55, count: 320))
        }

        let result = try await service.stopAndFinalize()
        guard case .requiresBatchFallback = result else {
            Issue.record("More than 750 ms of queued audio must force complete-file recovery")
            return
        }
        #expect((service.performanceSnapshot.droppedChunks ?? 0) > 0)
        #expect((service.performanceSnapshot.maxBacklogBytes ?? 0) <= StreamingAudioIntegrityPolicy.maximumBacklogBytes)
        #expect(service.performanceSnapshot.terminationReason == StreamingTerminationReason.sendBacklog.rawValue)
    }

    @MainActor
    @Test func doubaoStartupBacklogCoversBoundedConnectionRetry() async throws {
        let provider = IntegrityProbeProvider(connectDelay: .milliseconds(40))
        let service = try makeService(
            provider: provider,
            deadlines: StreamingDeadlines(startup: .milliseconds(200))
        )
        let model = IntegrityTestModel(provider: .doubaoSpeech)
        let bufferedAudio = Data(repeating: 0x31, count: 32_000)

        service.prepareForStart(model: model)
        service.sendAudioChunk(bufferedAudio)
        try await service.startStreaming(
            model: model,
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )

        let result = try await service.stopAndFinalize()
        guard case .finalized = result else {
            Issue.record("Audio captured during a bounded Doubao reconnect must remain streamable")
            return
        }
        #expect(service.performanceSnapshot.droppedChunks == 0)
        #expect(service.performanceSnapshot.receivedBytes == bufferedAudio.count)
        #expect(service.performanceSnapshot.sentBytes == bufferedAudio.count)
    }

    @MainActor
    @Test func standardProvidersKeepTheirExistingDeadlines() throws {
        let standardService = try makeService(provider: IntegrityProbeProvider())
        standardService.prepareForStart(model: IntegrityTestModel(provider: .deepgram))
        #expect(standardService.startupDeadline == .seconds(12))

        let doubaoService = try makeService(provider: IntegrityProbeProvider())
        doubaoService.prepareForStart(model: IntegrityTestModel(provider: .doubaoSpeech))
        #expect(doubaoService.startupDeadline == .milliseconds(8_500))
    }

    @MainActor
    @Test func standardProvidersRetainTheLegacySteadyStateQueueCapacity() async throws {
        let provider = IntegrityProbeProvider(sendDelay: .milliseconds(10))
        let service = try makeService(provider: provider)
        let model = IntegrityTestModel(provider: .deepgram)

        service.prepareForStart(model: model)
        try await service.startStreaming(
            model: model,
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        for _ in 0..<100 {
            service.sendAudioChunk(Data(repeating: 0x45, count: 320))
        }

        let result = try await service.stopAndFinalize()
        guard case .finalized = result else {
            Issue.record("A healthy standard provider must not inherit Doubao's 750 ms queue cap")
            return
        }
        #expect(service.performanceSnapshot.droppedChunks == 0)
        #expect(service.performanceSnapshot.sentBytes == 32_000)
    }

    @MainActor
    @Test func immediateCommitFailureIsNotReportedAsTimeout() async throws {
        let provider = IntegrityProbeProvider(commitError: IntegrityTestError.commitFailed)
        let service = try makeService(provider: provider)

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        do {
            _ = try await service.stopAndFinalize()
            Issue.record("A failed commit must be surfaced")
        } catch {
            // Expected.
        }

        #expect(service.performanceSnapshot.terminationReason == StreamingTerminationReason.commitFailure.rawValue)
    }

    @MainActor
    @Test func completeFileRecoveryCanContinuePublishingStreamingPartials() async throws {
        var previews: [String] = []
        let service = try makeService(
            provider: IntegrityProbeProvider(),
            onPartialTranscript: { previews.append($0) }
        )

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        await service.stopTransportForCompleteFileRecovery()
        service.beginCompleteFileStreamingRecovery()
        service.publishRecoveryPreview("retry partial")

        #expect(previews == ["retry partial"])
    }

    @MainActor
    @Test func providerAttemptCountIsIncludedInPerformanceSnapshot() async throws {
        let provider = IntegrityProbeProvider(observedAttemptCount: 1)
        let service = try makeService(provider: provider)

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )

        #expect(service.performanceSnapshot.concurrentAttemptCount == 1)
        service.cancel()
    }

    @MainActor
    @Test func repeatedCancellationKeepsTheOriginalDisconnectBarrier() async throws {
        let gate = StreamingDisconnectGate()
        let provider = GatedDisconnectProvider(gate: gate)
        let service = try makeService(provider: provider)

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        service.cancel()
        service.cancel()

        for _ in 0..<100 where !(await gate.didStart) {
            await Task.yield()
        }

        let waiter = Task { @MainActor in
            await service.waitForCancellation()
            return true
        }
        await Task.yield()
        #expect(!waiter.isCancelled)
        #expect(await gate.didStart)
        #expect(!(await gate.didFinish))

        await gate.release()
        #expect(await waiter.value)
        #expect(await gate.didFinish)
    }

    @MainActor
    @Test func sessionCancellationWaitsForNonCooperativeStreamingStartup() async throws {
        let startupGate = StreamingStartupGate()
        let provider = GatedStartupProvider(gate: startupGate)
        let service = try makeService(provider: provider)
        let session = StreamingTranscriptionSession(
            streamingService: service,
            fallbackService: IntegrityFallbackService()
        )
        let model = IntegrityTestModel(provider: .fluidAudio)
        let mode = ModeConfig(
            name: "Startup cancellation",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: model.name,
            isRealtimeTranscriptionEnabled: true
        )
        _ = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                mode: mode,
                model: model,
                language: "auto",
                isRealtimeEnabled: true
            )
        )
        for _ in 0..<100 where !(await startupGate.didStart) {
            await Task.yield()
        }

        session.cancel()
        let completion = StreamingCancellationCompletion()
        let waiter = Task { @MainActor in
            await session.waitForCancellation()
            await completion.finish()
        }
        await Task.yield()

        #expect(await startupGate.didStart)
        #expect(!(await startupGate.didFinish))
        #expect(!(await completion.didFinish))

        await startupGate.release()
        await waiter.value
        #expect(await startupGate.didFinish)
        #expect(await completion.didFinish)
    }

    @MainActor
    @Test func normalCleanupPreservesTimedOutDisconnectBarrier() async throws {
        let gate = StreamingDisconnectGate()
        let provider = GatedDisconnectProvider(gate: gate)
        let service = try makeService(
            provider: provider,
            deadlines: StreamingDeadlines(disconnect: .milliseconds(1))
        )

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        _ = try await service.stopAndFinalize()
        #expect(await gate.didStart)
        #expect(!(await gate.didFinish))

        let cleanupWaiter = Task { @MainActor in
            await service.waitForCancellation()
        }
        await Task.yield()
        #expect(!(await gate.didFinish))

        await gate.release()
        await cleanupWaiter.value
        #expect(await gate.didFinish)
    }

    @MainActor
    @Test func cancellationCleanupPreservesTimedOutCommitBarrier() async throws {
        let commitGate = StreamingStartupGate()
        let provider = GatedCommitProvider(gate: commitGate)
        let service = try makeService(
            provider: provider,
            deadlines: StreamingDeadlines(commit: .milliseconds(1))
        )

        service.prepareForStart()
        try await service.startStreaming(
            model: IntegrityTestModel(provider: .fluidAudio),
            context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        await #expect(throws: StreamingTranscriptionError.self) {
            _ = try await service.stopAndFinalize()
        }
        #expect(await commitGate.didStart)
        #expect(!(await commitGate.didFinish))

        let completion = StreamingCancellationCompletion()
        let waiter = Task { @MainActor in
            await service.waitForCancellation()
            await completion.finish()
        }
        await Task.yield()
        #expect(!(await completion.didFinish))

        await commitGate.release()
        await waiter.value
        #expect(await commitGate.didFinish)
        #expect(await completion.didFinish)
    }

    @MainActor
    private func makeService(
        provider: any StreamingTranscriptionProvider,
        deadlines: StreamingDeadlines? = nil,
        onPartialTranscript: (@MainActor (String) -> Void)? = nil
    ) throws -> StreamingTranscriptionService {
        let container = try ModelContainer(
            for: VocabularyWord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return StreamingTranscriptionService(
            modelContext: ModelContext(container),
            onPartialTranscript: onPartialTranscript,
            providerFactory: { _, _, _ in provider },
            deadlines: deadlines
        )
    }
}

private enum IntegrityTestError: Error {
    case sendFailed
    case receiveFailed
    case commitFailed
}

private actor StreamingDisconnectGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var didStart = false
    private(set) var didFinish = false

    func wait() async {
        didStart = true
        guard !isReleased else {
            didFinish = true
            return
        }
        await withCheckedContinuation { continuation = $0 }
        didFinish = true
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class GatedDisconnectProvider: StreamingTranscriptionProvider {
    private let gate: StreamingDisconnectGate
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(gate: StreamingDisconnectGate) {
        self.gate = gate
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {}
    func sendAudioChunk(_: Data) async throws {}
    func commit() async throws {
        continuation.yield(.committed(text: "complete"))
    }

    func disconnect() async {
        await gate.wait()
        continuation.finish()
    }
}

private actor StreamingStartupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var didStart = false
    private(set) var didFinish = false

    func wait() async {
        didStart = true
        if !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
        didFinish = true
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor StreamingCancellationCompletion {
    private(set) var didFinish = false

    func finish() {
        didFinish = true
    }
}

private final class GatedStartupProvider: StreamingTranscriptionProvider {
    private let gate: StreamingStartupGate
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(gate: StreamingStartupGate) {
        self.gate = gate
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {
        await gate.wait()
    }

    func sendAudioChunk(_: Data) async throws {}
    func commit() async throws {}

    func disconnect() async {
        continuation.finish()
    }
}

private final class GatedCommitProvider: StreamingTranscriptionProvider {
    private let gate: StreamingStartupGate
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(gate: StreamingStartupGate) {
        self.gate = gate
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {}
    func sendAudioChunk(_: Data) async throws {}

    func commit() async throws {
        await gate.wait()
        continuation.yield(.committed(text: "late"))
    }

    func disconnect() async {
        continuation.finish()
    }
}

private struct IntegrityFallbackService: TranscriptionService {
    func transcribe(
        audioURL _: URL,
        model _: any TranscriptionModel,
        context _: TranscriptionRequestContext
    ) async throws -> String {
        "fallback"
    }
}

private struct IntegrityTestModel: TranscriptionModel {
    let id = UUID()
    let name = "integrity-test"
    let displayName = "Integrity Test"
    let description = "Test model"
    let provider: ModelProvider
    let isMultilingualModel = true
    let supportedLanguages = ["auto": "Automatic"]
    let supportsStreaming = true

    init(provider: ModelProvider = .deepgram) {
        self.provider = provider
    }
}

private enum ReconnectTestError: Error {
    case connectionFailed
}

private final class ReconnectProviderSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ReconnectProbeProvider]
    private var storedRequestCount = 0

    init(_ providers: [ReconnectProbeProvider]) {
        self.providers = providers
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func next() -> ReconnectProbeProvider {
        lock.withLock {
            storedRequestCount += 1
            return providers.removeFirst()
        }
    }
}

private final class ReconnectProbeProvider: StreamingTranscriptionProvider {
    private let lock = NSLock()
    private let connectionError: Error?
    private var connectCount = 0
    private var disconnectCount = 0
    private var commitCount = 0
    private var sentAudio: [Data] = []
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(connectionError: Error? = nil) {
        self.connectionError = connectionError
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {
        lock.withLock { connectCount += 1 }
        if let connectionError {
            throw connectionError
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        lock.withLock { sentAudio.append(data) }
    }

    func commit() async throws {
        lock.withLock { commitCount += 1 }
        continuation.yield(.committed(text: "reconnected"))
    }

    func disconnect() async {
        lock.withLock { disconnectCount += 1 }
        continuation.finish()
    }

    func snapshot() -> (
        connectCount: Int,
        disconnectCount: Int,
        commitCount: Int,
        sentAudio: [Data]
    ) {
        lock.withLock { (connectCount, disconnectCount, commitCount, sentAudio) }
    }
}

private final class IntegrityProbeProvider: StreamingTranscriptionProvider {
    private let lock = NSLock()
    private let failSendAt: Int?
    private let errorOnCommit: Bool
    private let suppressCommitEvent: Bool
    private let sendDelay: Duration?
    private let connectDelay: Duration?
    private let commitError: Error?
    private let observedAttemptCount: Int?
    private var sendAttempts = 0
    private var sentBytes = 0
    private var commitCount = 0
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(
        failSendAt: Int? = nil,
        errorOnCommit: Bool = false,
        suppressCommitEvent: Bool = false,
        sendDelay: Duration? = nil,
        connectDelay: Duration? = nil,
        commitError: Error? = nil,
        observedAttemptCount: Int? = nil
    ) {
        self.failSendAt = failSendAt
        self.errorOnCommit = errorOnCommit
        self.suppressCommitEvent = suppressCommitEvent
        self.sendDelay = sendDelay
        self.connectDelay = connectDelay
        self.commitError = commitError
        self.observedAttemptCount = observedAttemptCount
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {
        if let connectDelay {
            try await Task.sleep(for: connectDelay)
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
        let shouldFail = lock.withLock {
            sendAttempts += 1
            sentBytes += data.count
            return sendAttempts == failSendAt
        }
        if shouldFail {
            throw IntegrityTestError.sendFailed
        }
    }

    func commit() async throws {
        lock.withLock { commitCount += 1 }
        if let commitError {
            throw commitError
        }
        if errorOnCommit {
            continuation.yield(.error(IntegrityTestError.receiveFailed))
        } else if !suppressCommitEvent {
            continuation.yield(.committed(text: "complete"))
        }
    }

    func disconnect() async {
        continuation.finish()
    }

    func observedConcurrentAttemptCount() async -> Int? {
        observedAttemptCount
    }

    func emit(error: Error) {
        continuation.yield(.error(error))
    }

    func emitSnapshot(text: String, stableText: String) {
        continuation.yield(.snapshot(text: text, stableText: stableText))
    }

    func snapshot() -> (sendAttempts: Int, sentBytes: Int, commitCount: Int) {
        lock.withLock { (sendAttempts, sentBytes, commitCount) }
    }
}
