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
        var events: [String] = []
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text, _ in
                events.append("pasted:\(text)")
                return .commandPosted
            },
            restoreInputTarget: { _ in
                events.append("restored")
                return .restored
            },
            captureEditableTextState: { _ in
                events.append("captured")
                return RecordingEditableTextState(
                    value: "prefix suffix",
                    selectedTextRange: CFRange(location: 7, length: 0)
                )
            },
            appendTrailingSpace: { true }
        )

        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: makeInputTarget(),
            dismiss: { events.append("dismissed") },
            shouldCancel: { false },
            onUserInteraction: {}
        )
        result.replacementSession?.stopMonitoring()

        #expect(result.wasDelivered)
        #expect(result.didPostPasteCommand)
        #expect(result.replacementSession != nil)
        #expect(events == ["dismissed", "restored", "captured", "pasted:raw "])
    }

    @Test func provisionalDeliveryWithoutReplacementSupportSkipsEnhancement() async {
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _, _ in .commandPosted },
            restoreInputTarget: { _ in .restored },
            captureEditableTextState: { _ in nil },
            appendTrailingSpace: { false }
        )

        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: makeInputTarget(),
            dismiss: {},
            shouldCancel: { false },
            onUserInteraction: {}
        )

        #expect(result.wasDelivered)
        #expect(result.didPostPasteCommand)
        #expect(result.replacementSession == nil)
        #expect(!result.shouldContinueEnhancement)
    }

    @Test func failedProvisionalDeliveryRetainsFinalEnhancementFallback() async {
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _, _ in .commandNotPosted },
            restoreInputTarget: { _ in .restored },
            captureEditableTextState: { _ in nil },
            appendTrailingSpace: { false }
        )

        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: makeInputTarget(),
            dismiss: {},
            shouldCancel: { false },
            onUserInteraction: {}
        )

        #expect(!result.wasDelivered)
        #expect(!result.didPostPasteCommand)
        #expect(result.replacementSession == nil)
        #expect(result.shouldContinueEnhancement)
    }

    @Test func clipboardFallbackIsDeliveredButNeverEligibleForAutoSend() async {
        var scheduledKeys: [AutoSendKey] = []
        let delivery = TranscriptionDelivery(
            restoreInputTarget: { _ in .unavailable },
            copyToClipboard: { _ in true },
            notifyUnavailableTarget: {},
            appendTrailingSpace: { false },
            autoSendScheduler: { key, _ in scheduledKeys.append(key) }
        )
        let target = makeInputTarget()
        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: target,
            dismiss: {},
            shouldCancel: { false },
            onUserInteraction: {}
        )
        let completion = await delivery.finishProvisionalDeliveryWithoutEnhancement(
            result.replacementSession,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .enter,
                customCommand: nil
            ),
            inputTarget: target,
            didPostPasteCommand: result.didPostPasteCommand
        )

        #expect(result.wasDelivered)
        #expect(!result.didPostPasteCommand)
        #expect(completion == .originalRetained)
        #expect(scheduledKeys.isEmpty)
    }

    @Test func canceledTargetRestorationDoesNotClaimClipboardDelivery() async {
        var copiedText: String?
        var pasteCount = 0
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _, _ in
                pasteCount += 1
                return .commandPosted
            },
            restoreInputTarget: { _ in .canceled },
            copyToClipboard: { text in
                copiedText = text
                return true
            },
            appendTrailingSpace: { false }
        )

        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: makeInputTarget(),
            dismiss: {},
            shouldCancel: { false },
            onUserInteraction: {}
        )

        #expect(!result.wasDelivered)
        #expect(!result.didPostPasteCommand)
        #expect(pasteCount == 0)
        #expect(copiedText == nil)
    }

    @Test func fullCancellationAfterRestorationPreventsProvisionalPaste() async {
        var isCanceled = false
        var pasteCount = 0
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _, _ in
                pasteCount += 1
                return .commandPosted
            },
            restoreInputTarget: { _ in
                isCanceled = true
                return .restored
            },
            appendTrailingSpace: { false }
        )

        let result = await delivery.deliverOriginalProvisionally(
            "raw",
            inputTarget: makeInputTarget(),
            dismiss: {},
            shouldCancel: { isCanceled },
            onUserInteraction: {}
        )

        #expect(!result.wasDelivered)
        #expect(!result.didPostPasteCommand)
        #expect(pasteCount == 0)
    }

    @Test func interactionFallbackPreservesClipboardAndReportsHistoryRecovery() {
        var copyCount = 0
        var interruptedNotificationCount = 0
        let delivery = TranscriptionDelivery(
            copyToClipboard: { _ in
                copyCount += 1
                return true
            },
            notifyInterruptedDelivery: { interruptedNotificationCount += 1 },
            appendTrailingSpace: { true }
        )

        delivery.reportOriginalNotInsertedAfterInteraction()

        #expect(copyCount == 0)
        #expect(interruptedNotificationCount == 1)
    }

    @Test func ordinaryInteractionSuppressesASecondAutomaticPaste() {
        #expect(TranscriptionDelivery.shouldSuppressRecoveryAfterInterruptedProvisionalPaste(
            wasCanceledByUser: true,
            recordingCanceled: false,
            explicitRecoveryRequested: false
        ))
    }

    @Test func explicitEnhancementBypassRecoversACanceledPrePasteAttempt() {
        #expect(!TranscriptionDelivery.shouldSuppressRecoveryAfterInterruptedProvisionalPaste(
            wasCanceledByUser: true,
            recordingCanceled: false,
            explicitRecoveryRequested: true
        ))
    }

    @Test func fullCancellationBeforeReplacementPreventsMutationAndAutoSend() async throws {
        var isCanceled = false
        var replacementCount = 0
        var scheduledKeys: [AutoSendKey] = []
        let session = try #require(ProvisionalTextReplacementSession(
            target: makeInputTarget(),
            preInsertionState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            insertedText: "raw",
            replacementText: "raw",
            startMonitoring: false,
            readState: { _ in
                isCanceled = true
                return RecordingEditableTextState(
                    value: "prefix rawsuffix",
                    selectedTextRange: CFRange(location: 10, length: 0)
                )
            },
            replaceText: { _, _, _, _, _, _ in
                replacementCount += 1
                return true
            },
            onUserInteraction: {}
        ))
        let delivery = TranscriptionDelivery(
            appendTrailingSpace: { false },
            autoSendScheduler: { key, _ in scheduledKeys.append(key) }
        )

        let result = await delivery.completeProvisionalDelivery(
            session,
            enhancedText: "enhanced",
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .enter,
                customCommand: nil
            ),
            inputTarget: makeInputTarget(),
            shouldCancel: { isCanceled }
        )

        #expect(result == .canceledByUser)
        #expect(replacementCount == 0)
        #expect(scheduledKeys.isEmpty)
    }

    @Test func fullCancellationDuringRetentionSuppressesAutoSend() async throws {
        var isCanceled = false
        var scheduledKeys: [AutoSendKey] = []
        let session = try #require(ProvisionalTextReplacementSession(
            target: makeInputTarget(),
            preInsertionState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            insertedText: "raw",
            replacementText: "raw",
            startMonitoring: false,
            readState: { _ in
                isCanceled = true
                return RecordingEditableTextState(
                    value: "prefix rawsuffix",
                    selectedTextRange: CFRange(location: 10, length: 0)
                )
            },
            onUserInteraction: {}
        ))
        let delivery = TranscriptionDelivery(
            appendTrailingSpace: { false },
            autoSendScheduler: { key, _ in scheduledKeys.append(key) }
        )

        let result = await delivery.finishProvisionalDeliveryWithoutEnhancement(
            session,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .enter,
                customCommand: nil
            ),
            inputTarget: makeInputTarget(),
            didPostPasteCommand: true,
            shouldCancel: { isCanceled }
        )

        #expect(result == .canceledByUser)
        #expect(scheduledKeys.isEmpty)
    }

    @Test func postedRawTextWithoutReplacementSupportRetainsAutoSend() async {
        var scheduledKeys: [AutoSendKey] = []
        let delivery = TranscriptionDelivery(
            appendTrailingSpace: { false },
            autoSendScheduler: { key, _ in scheduledKeys.append(key) }
        )

        let completion = await delivery.finishProvisionalDeliveryWithoutEnhancement(
            nil,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .enter,
                customCommand: nil
            ),
            inputTarget: makeInputTarget(),
            didPostPasteCommand: true
        )

        #expect(completion == .originalRetained)
        #expect(scheduledKeys == [.enter])
    }

    @Test func userBypassNeverAutoSendsAnAlreadyPostedRawTranscript() async {
        var scheduledKeys: [AutoSendKey] = []
        let delivery = TranscriptionDelivery(
            appendTrailingSpace: { false },
            autoSendScheduler: { key, _ in scheduledKeys.append(key) }
        )

        let completion = await delivery.finishProvisionalDeliveryWithoutEnhancement(
            nil,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .enter,
                customCommand: nil
            ),
            inputTarget: makeInputTarget(),
            didPostPasteCommand: true,
            verifyInsertionAfterCancellation: true
        )

        #expect(completion == .originalRetained)
        #expect(scheduledKeys.isEmpty)
    }

    @Test func skippingEnhancementPastesOriginalTextWithoutAutoSend() async {
        var pastedText: String?
        var dismissCount = 0
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text, _ in
                pastedText = text
                return .commandPosted
            },
            appendTrailingSpace: { false }
        )

        await delivery.pasteOriginalImmediately("original transcript", inputTarget: nil) {
            dismissCount += 1
        }

        #expect(pastedText == "original transcript")
        #expect(dismissCount == 1)
    }

    @Test(arguments: [CursorPaster.PasteResult.commandPosted, .commandNotPosted])
    func deliveryDoesNotReturnBeforePasteCommandResolves(_ pasteResult: CursorPaster.PasteResult) async throws {
        let transcription = Transcription(
            text: "original",
            duration: 1,
            transcriptionStatus: .completed
        )

        let gate = PasteCommandGate()
        var events: [String] = []
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text, _ in
                events.append("paste-started:\(text)")
                return await gate.performPaste()
            },
            appendTrailingSpace: { false }
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
        var events: [String] = []
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { text, _ in
                events.append("pasted:\(text)")
                return .commandPosted
            },
            restoreInputTarget: { _ in
                events.append("restored")
                return .restored
            },
            appendTrailingSpace: { false }
        )

        await delivery.pasteOriginalImmediately("targeted", inputTarget: makeInputTarget()) {
            events.append("dismissed")
        }

        #expect(events == ["dismissed", "restored", "pasted:targeted"])
    }

    @Test func unavailableCapturedInputCopiesWithoutPasting() async {
        var events: [String] = []
        var copiedText: String?
        var pasteCount = 0
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _, _ in
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
            },
            appendTrailingSpace: { false }
        )

        await delivery.pasteOriginalImmediately("safe fallback", inputTarget: makeInputTarget()) {
            events.append("dismissed")
        }

        #expect(pasteCount == 0)
        #expect(copiedText == "safe fallback")
        #expect(events == ["dismissed", "unavailable", "copied", "notified"])
    }

    @Test func enhancementFailureAutoSendsOnlyAnUntouchedRawTranscript() async throws {
        var scheduledKeys: [AutoSendKey] = []
        let delivery = TranscriptionDelivery(
            appendTrailingSpace: { false },
            autoSendScheduler: { key, _ in scheduledKeys.append(key) }
        )
        let session = try #require(ProvisionalTextReplacementSession(
            target: makeInputTarget(),
            preInsertionState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            insertedText: "raw",
            replacementText: "raw",
            startMonitoring: false,
            readState: { _ in
                RecordingEditableTextState(
                    value: "prefix rawsuffix",
                    selectedTextRange: CFRange(location: 10, length: 0)
                )
            },
            onUserInteraction: {}
        ))
        let output = OutputRuntimeConfiguration(
            mode: nil,
            outputMode: .paste,
            autoSendKey: .enter,
            customCommand: nil
        )

        let retained = await delivery.finishProvisionalDeliveryWithoutEnhancement(
            session,
            output: output,
            inputTarget: makeInputTarget(),
            didPostPasteCommand: true
        )

        #expect(retained == .originalRetained)
        #expect(scheduledKeys == [.enter])

        session.registerUserInteraction()
        let canceled = await delivery.finishProvisionalDeliveryWithoutEnhancement(
            session,
            output: output,
            inputTarget: makeInputTarget(),
            didPostPasteCommand: true
        )

        #expect(canceled == .canceledByUser)
        #expect(scheduledKeys == [.enter])
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
}
