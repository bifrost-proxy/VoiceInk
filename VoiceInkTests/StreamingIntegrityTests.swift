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
    let provider = ModelProvider.deepgram
    let isMultilingualModel = true
    let supportedLanguages = ["auto": "Automatic"]
    let supportsStreaming = true
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
