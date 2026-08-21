import ApplicationServices
import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct ProvisionalTextReplacementSessionTests {
    @Test func onlySuccessfulReplacementPersistsEnhancement() {
        #expect(ProvisionalTextReplacementSession.ReplacementResult.replaced.shouldPersistEnhancement)
        #expect(!ProvisionalTextReplacementSession.ReplacementResult.originalRetained.shouldPersistEnhancement)
        #expect(!ProvisionalTextReplacementSession.ReplacementResult.originalNotInserted.shouldPersistEnhancement)
        #expect(!ProvisionalTextReplacementSession.ReplacementResult.canceledByUser.shouldPersistEnhancement)
        #expect(!ProvisionalTextReplacementSession.ReplacementResult.targetChanged.shouldPersistEnhancement)
        #expect(!ProvisionalTextReplacementSession.ReplacementResult.unavailable.shouldPersistEnhancement)
    }

    @Test func unchangedPreInsertionStateReportsDroppedPasteCommand() async throws {
        let session = try #require(makeSession(
            currentState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            replaceText: { _, _, _, _, _, _ in true }
        ))

        let result = await session.replace(with: "enhanced")

        #expect(result == .originalNotInserted)
    }

    @Test func canceledBypassStillDetectsDroppedPasteCommand() async throws {
        let session = try #require(makeSession(
            currentState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            replaceText: { _, _, _, _, _, _ in true }
        ))

        let task = Task { @MainActor in
            await session.finishKeepingOriginal(verifyInsertionAfterCancellation: true)
        }
        task.cancel()

        #expect(await task.value == .originalNotInserted)
    }

    @Test func successfulReplacementUpdatesOnlyItsOwnedClipboardText() async throws {
        let ownership = CursorPaster.ClipboardOwnership(
            sessionID: "session",
            changeCount: 7,
            expectedText: "raw "
        )
        var updatedClipboardText: String?
        let session = try #require(ProvisionalTextReplacementSession(
            target: makeInputTarget(),
            preInsertionState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            insertedText: "raw ",
            replacementText: "raw",
            clipboardOwnership: ownership,
            startMonitoring: false,
            readState: { _ in
                RecordingEditableTextState(
                    value: "prefix raw suffix",
                    selectedTextRange: CFRange(location: 11, length: 0)
                )
            },
            replaceText: { _, _, _, _, _, _ in true },
            updateClipboard: { receivedOwnership, text in
                #expect(receivedOwnership == ownership)
                updatedClipboardText = text
                return true
            },
            onUserInteraction: {}
        ))

        #expect(await session.replace(with: "enhanced") == .replaced)
        #expect(updatedClipboardText == "enhanced ")
    }

    @Test func clipboardOwnershipRejectsAnyNewPasteboardState() {
        let ownership = CursorPaster.ClipboardOwnership(
            sessionID: "session",
            changeCount: 7,
            expectedText: "raw"
        )
        #expect(CursorPaster.stillOwnsClipboard(
            ownership,
            changeCount: 7,
            text: "raw",
            sessionID: "session"
        ))
        #expect(!CursorPaster.stillOwnsClipboard(
            ownership,
            changeCount: 8,
            text: "raw",
            sessionID: "session"
        ))
        #expect(!CursorPaster.stillOwnsClipboard(
            ownership,
            changeCount: 7,
            text: "new user copy",
            sessionID: "session"
        ))
        #expect(!CursorPaster.stillOwnsClipboard(
            ownership,
            changeCount: 7,
            text: "raw",
            sessionID: "another session"
        ))
    }

    @Test func editableTextSnapshotsHaveAConservativeUTF16Limit() {
        let limit = RecordingInputTargetService.maximumEditableTextUTF16Length
        #expect(RecordingInputTargetService.isWithinEditableTextLimit(limit))
        #expect(!RecordingInputTargetService.isWithinEditableTextLimit(limit + 1))
        #expect(!RecordingInputTargetService.isWithinEditableTextLimit(-1))
    }

    @Test func targetRestorationWaitStopsWhenItsTaskIsCanceled() async {
        let task = Task { @MainActor in
            await RecordingInputTargetService.waitUntil(timeout: .seconds(1)) { false }
        }
        await Task.yield()
        task.cancel()

        #expect(await task.value == false)
    }

    @Test func rollbackOwnershipRejectsCancellationAndConcurrentEdits() {
        let transactionState = RecordingEditableTextState(
            value: "prefix enhanced suffix",
            selectedTextRange: CFRange(location: 15, length: 0)
        )
        let expectedRanges = [CFRange(location: 15, length: 0)]
        #expect(RecordingInputTargetService.ownsProvisionalReplacementState(
            transactionState,
            expectedTransactionValue: "prefix enhanced suffix",
            transactionSelectionRanges: expectedRanges,
            isCanceled: false
        ))
        #expect(!RecordingInputTargetService.ownsProvisionalReplacementState(
            RecordingEditableTextState(
                value: "prefix enhanced plus user edit suffix",
                selectedTextRange: CFRange(location: 15, length: 0)
            ),
            expectedTransactionValue: "prefix enhanced suffix",
            transactionSelectionRanges: expectedRanges,
            isCanceled: false
        ))
        #expect(!RecordingInputTargetService.ownsProvisionalReplacementState(
            RecordingEditableTextState(
                value: "prefix enhanced suffix",
                selectedTextRange: CFRange(location: 2, length: 0)
            ),
            expectedTransactionValue: "prefix enhanced suffix",
            transactionSelectionRanges: expectedRanges,
            isCanceled: false
        ))
        #expect(!RecordingInputTargetService.ownsProvisionalReplacementState(
            transactionState,
            expectedTransactionValue: "prefix enhanced suffix",
            transactionSelectionRanges: expectedRanges,
            isCanceled: true
        ))
        #expect(RecordingInputTargetService.ownsProvisionalReplacementState(
            transactionState,
            expectedTransactionValue: "prefix enhanced suffix",
            transactionSelectionRanges: expectedRanges,
            isCanceled: true,
            permitObservedCancellation: true
        ))
    }

    @Test func replacesOnlyOriginalUTF16RangeAndPreservesSurroundingText() async throws {
        let originalValue = "前😀被选中后"
        let selectedRange = (originalValue as NSString).range(of: "被选中")
        let preState = RecordingEditableTextState(
            value: originalValue,
            selectedTextRange: CFRange(location: selectedRange.location, length: selectedRange.length)
        )
        let rawText = "原始🎙️"
        let insertedText = rawText + " "
        let expectedPostValue = (originalValue as NSString).replacingCharacters(
            in: selectedRange,
            with: insertedText
        )
        let expectedCaret = CFRange(
            location: selectedRange.location + (insertedText as NSString).length,
            length: 0
        )
        var currentState = RecordingEditableTextState(
            value: expectedPostValue,
            selectedTextRange: expectedCaret
        )
        var replacedRange: CFRange?

        let session = try #require(ProvisionalTextReplacementSession(
            target: makeInputTarget(),
            preInsertionState: preState,
            insertedText: insertedText,
            replacementText: rawText,
            startMonitoring: false,
            readState: { _ in currentState },
            replaceText: { _, range, replacement, expectedValue, _, shouldCancel in
                guard !shouldCancel() else { return false }
                replacedRange = range
                currentState = RecordingEditableTextState(
                    value: (expectedValue as NSString).replacingCharacters(
                        in: NSRange(location: range.location, length: range.length),
                        with: replacement
                    ),
                    selectedTextRange: CFRange(
                        location: range.location + (replacement as NSString).length,
                        length: 0
                    )
                )
                return true
            },
            onUserInteraction: {}
        ))

        let result = await session.replace(with: "润色✅")

        #expect(result == .replaced)
        #expect(replacedRange?.location == selectedRange.location)
        #expect(replacedRange?.length == (rawText as NSString).length)
        #expect(currentState.value == "前😀润色✅ 后")
    }

    @Test func userInteractionCancelsReplacementWithoutMutation() async throws {
        var interactionCount = 0
        var replacementCount = 0
        let session = try #require(makeSession(
            currentState: RecordingEditableTextState(
                value: "prefix raw suffix",
                selectedTextRange: CFRange(location: 10, length: 0)
            ),
            replaceText: { _, _, _, _, _, _ in
                replacementCount += 1
                return true
            },
            onUserInteraction: { interactionCount += 1 }
        ))

        session.registerUserInteraction()
        session.registerUserInteraction()
        let result = await session.replace(with: "enhanced")

        #expect(result == .canceledByUser)
        #expect(interactionCount == 1)
        #expect(replacementCount == 0)
    }

    @Test func changedContentLeavesRawTranscriptUntouched() async throws {
        var replacementCount = 0
        let session = try #require(makeSession(
            currentState: RecordingEditableTextState(
                value: "prefix raw plus user edit suffix",
                selectedTextRange: CFRange(location: 10, length: 0)
            ),
            replaceText: { _, _, _, _, _, _ in
                replacementCount += 1
                return true
            }
        ))

        let result = await session.replace(with: "enhanced")

        #expect(result == .targetChanged)
        #expect(replacementCount == 0)
    }

    @Test func movedCaretLeavesRawTranscriptUntouched() async throws {
        var replacementCount = 0
        let session = try #require(makeSession(
            currentState: RecordingEditableTextState(
                value: "prefix raw suffix",
                selectedTextRange: CFRange(location: 0, length: 0)
            ),
            replaceText: { _, _, _, _, _, _ in
                replacementCount += 1
                return true
            }
        ))

        let result = await session.replace(with: "enhanced")

        #expect(result == .targetChanged)
        #expect(replacementCount == 0)
    }

    @Test func taskCancellationStopsThePastePropagationWait() async throws {
        var replacementCount = 0
        let session = try #require(makeSession(
            currentState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            replaceText: { _, _, _, _, _, _ in
                replacementCount += 1
                return true
            }
        ))

        let replacementTask = Task { @MainActor in
            await session.replace(with: "enhanced")
        }
        await Task.yield()
        replacementTask.cancel()

        let result = await replacementTask.value
        #expect(result == .canceledByUser)
        #expect(replacementCount == 0)
    }

    private func makeSession(
        currentState: RecordingEditableTextState,
        replaceText: @escaping ProvisionalTextReplacementSession.ReplaceText,
        onUserInteraction: @escaping @MainActor () -> Void = {}
    ) -> ProvisionalTextReplacementSession? {
        ProvisionalTextReplacementSession(
            target: makeInputTarget(),
            preInsertionState: RecordingEditableTextState(
                value: "prefix suffix",
                selectedTextRange: CFRange(location: 7, length: 0)
            ),
            insertedText: "raw ",
            replacementText: "raw",
            startMonitoring: false,
            readState: { _ in currentState },
            replaceText: replaceText,
            onUserInteraction: onUserInteraction
        )
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
