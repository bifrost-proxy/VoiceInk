import Foundation
import Testing
@testable import VoiceInk

struct LocalModelResourceRetentionTests {
    @Test func boundModelNamesIncludesEveryModeReference() {
        let configurations = [
            mode(name: "Default", modelName: "qwen-local"),
            mode(name: "Disabled", modelName: "whisper-local", isEnabled: false),
            mode(name: "Cloud", modelName: " cloud-model "),
            mode(name: "Missing", modelName: nil),
            mode(name: "Blank", modelName: "   "),
        ]

        #expect(
            LocalModelResourceRetentionPolicy.boundModelNames(in: configurations)
                == ["qwen-local", "whisper-local", "cloud-model"]
        )
    }

    @MainActor
    @Test func managedSessionReleasesItsResourceLeaseOnceAfterTranscription() async throws {
        let baseSession = ResourceRetentionTestSession(result: "done")
        var finishCount = 0
        let session = ResourceManagedTranscriptionSession(session: baseSession) {
            finishCount += 1
        }

        let result = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        session.cancel()

        #expect(result == "done")
        #expect(baseSession.cancelCount == 1)
        #expect(finishCount == 1)
    }

    @MainActor
    @Test func managedSessionReleasesItsResourceLeaseOnceAfterCancellation() async {
        let baseSession = ResourceRetentionTestSession(result: "unused")
        var finishCount = 0
        let session = ResourceManagedTranscriptionSession(session: baseSession) {
            finishCount += 1
        }

        session.cancel()
        session.cancel()

        for _ in 0..<20 where finishCount == 0 {
            await Task.yield()
        }

        #expect(baseSession.cancelCount == 2)
        #expect(finishCount == 1)
    }

    @MainActor
    @Test func managedSessionRetainsItsLeaseUntilCancelledInferenceReturns() async throws {
        let gate = ResourceRetentionTaskGate()
        let baseSession = ResourceRetentionTestSession(result: "done", transcriptionGate: gate)
        var finishCount = 0
        let session = ResourceManagedTranscriptionSession(session: baseSession) {
            finishCount += 1
        }

        let transcriptionTask = Task { @MainActor in
            try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        }
        await Task.yield()
        session.cancel()
        #expect(finishCount == 0)

        await gate.release()
        _ = try await transcriptionTask.value
        #expect(finishCount == 1)
    }

    @MainActor
    @Test func managedSessionWaitsForCancellationAfterInferenceReturns() async throws {
        let transcriptionGate = ResourceRetentionTaskGate()
        let cancellationGate = ResourceRetentionTaskGate()
        let baseSession = ResourceRetentionTestSession(
            result: "done",
            transcriptionGate: transcriptionGate,
            cancellationGate: cancellationGate
        )
        var finishCount = 0
        let session = ResourceManagedTranscriptionSession(session: baseSession) {
            finishCount += 1
        }

        let transcriptionTask = Task { @MainActor in
            try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        }
        await Task.yield()
        session.cancel()
        await transcriptionGate.release()
        await Task.yield()

        #expect(finishCount == 0)

        await cancellationGate.release()
        #expect(try await transcriptionTask.value == "done")
        #expect(finishCount == 1)
    }

    @MainActor
    @Test func managedSessionRetainsItsLeaseUntilStreamingCancellationFinishes() async {
        let gate = ResourceRetentionTaskGate()
        let baseSession = ResourceRetentionTestSession(result: "unused", cancellationGate: gate)
        var finishCount = 0
        let session = ResourceManagedTranscriptionSession(session: baseSession) {
            finishCount += 1
        }

        session.cancel()
        await Task.yield()
        #expect(finishCount == 0)

        await gate.release()
        for _ in 0..<20 where finishCount == 0 {
            await Task.yield()
        }
        #expect(finishCount == 1)
    }

    @MainActor
    @Test func managedSessionRetainsItselfUntilStreamingCancellationFinishes() async {
        let gate = ResourceRetentionTaskGate()
        let baseSession = ResourceRetentionTestSession(result: "unused", cancellationGate: gate)
        var finishCount = 0
        var session: ResourceManagedTranscriptionSession? = ResourceManagedTranscriptionSession(
            session: baseSession
        ) {
            finishCount += 1
        }
        weak let retainedSession = session

        session?.cancel()
        session = nil
        await Task.yield()

        #expect(retainedSession != nil)
        #expect(finishCount == 0)

        await gate.release()
        for _ in 0..<20 where retainedSession != nil {
            await Task.yield()
        }

        #expect(retainedSession == nil)
        #expect(finishCount == 1)
    }

    @MainActor
    @Test func managedSessionReleasesItsResourceLeaseWhenPreparationFails() async {
        let baseSession = ResourceRetentionTestSession(
            result: "unused",
            preparationError: ResourceRetentionTestError.expected
        )
        var finishCount = 0
        let session = ResourceManagedTranscriptionSession(session: baseSession) {
            finishCount += 1
        }
        let configuration = TranscriptionRuntimeConfiguration(
            mode: mode(name: "Test", modelName: "resource-retention-test"),
            model: ResourceRetentionTestModel(),
            language: "auto",
            isRealtimeEnabled: false
        )

        await #expect(throws: ResourceRetentionTestError.self) {
            _ = try await session.prepare(configuration: configuration)
        }
        #expect(finishCount == 1)
    }

    private func mode(
        name: String,
        modelName: String?,
        isEnabled: Bool = true
    ) -> ModeConfig {
        ModeConfig(
            name: name,
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: modelName,
            isEnabled: isEnabled
        )
    }
}

@MainActor
private final class ResourceRetentionTestSession: TranscriptionSession {
    let result: String
    let preparationError: Error?
    private(set) var cancelCount = 0
    let transcriptionGate: ResourceRetentionTaskGate?
    let cancellationGate: ResourceRetentionTaskGate?

    init(
        result: String,
        preparationError: Error? = nil,
        transcriptionGate: ResourceRetentionTaskGate? = nil,
        cancellationGate: ResourceRetentionTaskGate? = nil
    ) {
        self.result = result
        self.preparationError = preparationError
        self.transcriptionGate = transcriptionGate
        self.cancellationGate = cancellationGate
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        if let preparationError {
            throw preparationError
        }
        return nil
    }

    func transcribe(audioURL: URL) async throws -> String {
        if let transcriptionGate {
            await transcriptionGate.wait()
        }
        return result
    }

    func cancel() {
        cancelCount += 1
    }

    func waitForCancellation() async {
        if let cancellationGate {
            await cancellationGate.wait()
        }
    }
}

private actor ResourceRetentionTaskGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private enum ResourceRetentionTestError: Error {
    case expected
}

private struct ResourceRetentionTestModel: TranscriptionModel {
    let id = UUID()
    let name = "resource-retention-test"
    let displayName = "Resource Retention Test"
    let description = ""
    let provider = ModelProvider.whisper
    let isMultilingualModel = true
    let supportedLanguages: [String: String] = [:]
    let supportsStreaming = false
    let officialSourceURL: URL? = nil
}
