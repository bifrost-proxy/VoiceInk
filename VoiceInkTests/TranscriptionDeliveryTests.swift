import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
private final class PasteCommandGate {
    private(set) var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<CursorPaster.PasteResult, Never>?

    func performPaste() async -> CursorPaster.PasteResult {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with result: CursorPaster.PasteResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

@MainActor
struct TranscriptionDeliveryTests {
    @Test(arguments: [CursorPaster.PasteResult.commandPosted, .commandNotPosted])
    func deliveryDoesNotReturnBeforePasteCommandResolves(_ pasteResult: CursorPaster.PasteResult) async throws {
        let defaults = UserDefaults.standard
        let previousTracking = defaults.object(forKey: PostPasteEditTracker.userDefaultsKey)
        let previousAppendSpace = defaults.object(forKey: "AppendTrailingSpace")
        defer {
            restore(previousTracking, forKey: PostPasteEditTracker.userDefaultsKey, in: defaults)
            restore(previousAppendSpace, forKey: "AppendTrailingSpace", in: defaults)
        }
        defaults.set(false, forKey: PostPasteEditTracker.userDefaultsKey)
        defaults.set(false, forKey: "AppendTrailingSpace")

        let schema = Schema([Transcription.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let transcription = Transcription(
            text: "original",
            duration: 1,
            transcriptionStatus: .completed
        )
        container.mainContext.insert(transcription)

        let gate = PasteCommandGate()
        var events: [String] = []
        let delivery = TranscriptionDelivery(
            modelContext: container.mainContext,
            pasteAtCursor: { text in
                events.append("paste-started:\(text)")
                return await gate.performPaste()
            }
        )

        let deliveryTask = Task { @MainActor in
            await delivery.deliver(
                TranscriptionDelivery.Request(
                    transcription: transcription,
                    text: "enhanced",
                    output: OutputRuntimeConfiguration(
                        mode: nil,
                        outputMode: .paste,
                        autoSendKey: .none,
                        customCommand: nil
                    ),
                    responseConfig: nil,
                    responseError: nil,
                    isAssistantFollowUp: false
                ),
                actions: TranscriptionDelivery.Actions(
                    setState: { _ in },
                    dismiss: { events.append("dismissed") },
                    sendFollowUp: { _, _ in },
                    showResponse: { _, _ in },
                    failResponse: { _ in }
                )
            )
            events.append("delivery-returned")
        }

        await gate.waitUntilStarted()
        #expect(events == ["dismissed", "paste-started:enhanced"])

        gate.finish(with: pasteResult)
        await deliveryTask.value

        #expect(events == ["dismissed", "paste-started:enhanced", "delivery-returned"])
        #expect(transcription.pasteTrackingStatusValue == .disabled)
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
