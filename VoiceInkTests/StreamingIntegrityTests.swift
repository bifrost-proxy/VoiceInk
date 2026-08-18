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
    }

    @MainActor
    private func makeService(provider: IntegrityProbeProvider) throws -> StreamingTranscriptionService {
        let container = try ModelContainer(
            for: VocabularyWord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return StreamingTranscriptionService(
            modelContext: ModelContext(container),
            providerFactory: { _, _, _ in provider }
        )
    }
}

private enum IntegrityTestError: Error {
    case sendFailed
    case receiveFailed
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
    private var sendAttempts = 0
    private var commitCount = 0
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(failSendAt: Int? = nil, errorOnCommit: Bool = false) {
        self.failSendAt = failSendAt
        self.errorOnCommit = errorOnCommit
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {}

    func sendAudioChunk(_: Data) async throws {
        let shouldFail = lock.withLock {
            sendAttempts += 1
            return sendAttempts == failSendAt
        }
        if shouldFail {
            throw IntegrityTestError.sendFailed
        }
    }

    func commit() async throws {
        lock.withLock { commitCount += 1 }
        if errorOnCommit {
            continuation.yield(.error(IntegrityTestError.receiveFailed))
        } else {
            continuation.yield(.committed(text: "complete"))
        }
    }

    func disconnect() async {
        continuation.finish()
    }

    func emit(error: Error) {
        continuation.yield(.error(error))
    }

    func snapshot() -> (sendAttempts: Int, commitCount: Int) {
        lock.withLock { (sendAttempts, commitCount) }
    }
}
