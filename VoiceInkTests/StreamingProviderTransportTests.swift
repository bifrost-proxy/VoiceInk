import Foundation
import Testing

@testable import VoiceInk

struct StreamingProviderTransportTests {
    @MainActor
    @Test func connectionWorkDoesNotBlockTheMainActorAndIsNotReused() async throws {
        let provider = TransportProbeProvider(connectDelay: 0.2)
        let transport = StreamingProviderTransport(provider: provider)
        let model = TransportTestModel()

        let startedAt = Date()
        let connection = Task {
            try await transport.connect(model: model, language: "auto")
        }

        try await Task.sleep(for: .milliseconds(20))
        #expect(Date().timeIntervalSince(startedAt) < 0.1)

        try await connection.value
        await transport.disconnect()

        let snapshot = provider.snapshot()
        #expect(snapshot.connectCount == 1)
        #expect(snapshot.disconnectCount == 1)
        #expect(!snapshot.connectedOnMainThread)
    }
}

private struct TransportTestModel: TranscriptionModel {
    let id = UUID()
    let name = "transport-test"
    let displayName = "Transport Test"
    let description = "Test model"
    let provider = ModelProvider.deepgram
    let isMultilingualModel = true
    let supportedLanguages = ["auto": "Automatic"]
    let supportsStreaming = true
}

private final class TransportProbeProvider: StreamingTranscriptionProvider {
    private let lock = NSLock()
    private let connectDelay: TimeInterval
    private var connectCount = 0
    private var disconnectCount = 0
    private var connectedOnMainThread = false

    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(connectDelay: TimeInterval) {
        self.connectDelay = connectDelay
        transcriptionEvents = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {
        lock.lock()
        connectCount += 1
        connectedOnMainThread = Thread.isMainThread
        lock.unlock()

        Thread.sleep(forTimeInterval: connectDelay)
    }

    func sendAudioChunk(_: Data) async throws {}

    func commit() async throws {}

    func disconnect() async {
        lock.lock()
        disconnectCount += 1
        lock.unlock()
    }

    func snapshot() -> (connectCount: Int, disconnectCount: Int, connectedOnMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (connectCount, disconnectCount, connectedOnMainThread)
    }
}
