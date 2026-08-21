import ApplicationServices
import Foundation
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
    @Test func provisionalDeliveryPastesRawTextBeforeEnhancementCanComplete() async throws {
        let defaults = UserDefaults.standard
        let previousAppendSpace = defaults.object(forKey: "AppendTrailingSpace")
        defer {
            restore(previousAppendSpace, forKey: "AppendTrailingSpace", in: defaults)
        }
        defaults.set(true, forKey: "AppendTrailingSpace")

        var events: [String] = []
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text in
                events.append("pasted:\(text)")
                return .commandPosted
            },
            restoreInputTarget: { _ in
                events.append("restored")
                return .restored
            },
            captureEditableTextState: { _ in
                RecordingEditableTextState(
                    value: "prefix suffix",
                    selectedTextRange: CFRange(location: 7, length: 0)
                )
            }
        )

        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: makeInputTarget(),
            dismiss: { events.append("dismissed") },
            onUserInteraction: {}
        )
        result.replacementSession?.stopMonitoring()

        #expect(result.wasDelivered)
        #expect(result.replacementSession != nil)
        #expect(events == ["dismissed", "restored", "pasted:raw "])
    }

    @Test func skippingEnhancementPastesOriginalTextWithoutAutoSend() async {
        let defaults = UserDefaults.standard
        let previousAppendSpace = defaults.object(forKey: "AppendTrailingSpace")
        defer {
            restore(previousAppendSpace, forKey: "AppendTrailingSpace", in: defaults)
        }
        defaults.set(false, forKey: "AppendTrailingSpace")

        var pastedText: String?
        var dismissCount = 0
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text in
                pastedText = text
                return .commandPosted
            }
        )

        await delivery.pasteOriginalImmediately("original transcript", inputTarget: nil) {
            dismissCount += 1
        }

        #expect(pastedText == "original transcript")
        #expect(dismissCount == 1)
    }

    @Test(arguments: [CursorPaster.PasteResult.commandPosted, .commandNotPosted])
    func deliveryDoesNotReturnBeforePasteCommandResolves(_ pasteResult: CursorPaster.PasteResult) async throws {
        let defaults = UserDefaults.standard
        let previousAppendSpace = defaults.object(forKey: "AppendTrailingSpace")
        defer {
            restore(previousAppendSpace, forKey: "AppendTrailingSpace", in: defaults)
        }
        defaults.set(false, forKey: "AppendTrailingSpace")

        let transcription = Transcription(
            text: "original",
            duration: 1,
            transcriptionStatus: .completed
        )

        let gate = PasteCommandGate()
        var events: [String] = []
        let delivery = TranscriptionDelivery(
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
                    isAssistantFollowUp: false,
                    inputTarget: nil
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
    }

    @Test func restoresCapturedInputBeforePasting() async {
        let defaults = UserDefaults.standard
        let previousAppendSpace = defaults.object(forKey: "AppendTrailingSpace")
        defer {
            restore(previousAppendSpace, forKey: "AppendTrailingSpace", in: defaults)
        }
        defaults.set(false, forKey: "AppendTrailingSpace")

        var events: [String] = []
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text in
                events.append("pasted:\(text)")
                return .commandPosted
            },
            restoreInputTarget: { _ in
                events.append("restored")
                return .restored
            }
        )

        await delivery.pasteOriginalImmediately("targeted", inputTarget: makeInputTarget()) {
            events.append("dismissed")
        }

        #expect(events == ["dismissed", "restored", "pasted:targeted"])
    }

    @Test func unavailableCapturedInputCopiesWithoutPasting() async {
        let defaults = UserDefaults.standard
        let previousAppendSpace = defaults.object(forKey: "AppendTrailingSpace")
        defer {
            restore(previousAppendSpace, forKey: "AppendTrailingSpace", in: defaults)
        }
        defaults.set(false, forKey: "AppendTrailingSpace")

        var events: [String] = []
        var copiedText: String?
        var pasteCount = 0
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _ in
                pasteCount += 1
                return .commandPosted
            },
            restoreInputTarget: { _ in
                events.append("unavailable")
                return .unavailable
            },
            copyToClipboard: { text in
                copiedText = text
                events.append("copied")
                return true
            },
            notifyUnavailableTarget: {
                events.append("notified")
            }
        )

        await delivery.pasteOriginalImmediately("safe fallback", inputTarget: makeInputTarget()) {
            events.append("dismissed")
        }

        #expect(pasteCount == 0)
        #expect(copiedText == "safe fallback")
        #expect(events == ["dismissed", "unavailable", "copied", "notified"])
    }

    private func makeInputTarget() -> RecordingInputTarget {
        RecordingInputTarget(
            processID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            window: nil,
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: nil
        )
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
