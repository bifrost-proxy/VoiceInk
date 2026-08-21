import AppKit
import Foundation
import os

private final class ProvisionalInteractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var ignorePasteShortcutUntil: TimeInterval = 0

    var isCanceled: Bool {
        lock.withLock { canceled }
    }

    @discardableResult
    func cancel() -> Bool {
        lock.withLock {
            guard !canceled else { return false }
            canceled = true
            return true
        }
    }

    func beginIgnoringPasteShortcut() {
        lock.withLock {
            ignorePasteShortcutUntil = ProcessInfo.processInfo.systemUptime + 0.5
        }
    }

    func finishIgnoringPasteShortcut() {
        lock.withLock {
            ignorePasteShortcutUntil = max(
                ignorePasteShortcutUntil,
                ProcessInfo.processInfo.systemUptime + 0.1
            )
        }
    }

    func shouldIgnore(_ event: NSEvent) -> Bool {
        lock.withLock {
            ProcessInfo.processInfo.systemUptime <= ignorePasteShortcutUntil
                && event.type == .keyDown
                && event.keyCode == 0x09
                && event.modifierFlags.contains(.command)
        }
    }
}

/// Owns one short-lived, in-memory transaction for replacing a raw transcript after enhancement.
/// The transaction fails closed: any user interaction or target-state mismatch leaves the raw text intact.
@MainActor
final class ProvisionalTextReplacementSession {
    enum ReplacementResult: Equatable {
        case replaced
        case originalRetained
        case originalNotInserted
        case originalNotInsertedAfterInteraction
        case canceledByUser
        case targetChanged
        case unavailable

        var shouldPersistEnhancement: Bool {
            self == .replaced
        }
    }

    typealias ReadState = @MainActor (RecordingInputTarget) -> RecordingEditableTextState?
    typealias ReplaceText = @MainActor (
        RecordingInputTarget,
        CFRange,
        String,
        String,
        CFRange,
        @escaping @MainActor @Sendable () -> Bool
    ) -> Bool
    typealias UpdateClipboard = @MainActor (CursorPaster.ClipboardOwnership, String) -> Bool

    private let target: RecordingInputTarget
    private let preInsertionState: RecordingEditableTextState
    private let expectedPostInsertionValue: String
    private let replacementRange: CFRange
    private let expectedCaret: CFRange
    private let enhancedClipboardSuffix: String
    private var clipboardOwnership: CursorPaster.ClipboardOwnership?
    private let readState: ReadState
    private let replaceText: ReplaceText
    private let updateClipboard: UpdateClipboard
    private let onUserInteraction: @MainActor () -> Void
    private let interactionCancellation = ProvisionalInteractionCancellation()
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "ProvisionalTextReplacement"
    )

    private var globalEventMonitor: Any?

    private enum PastePropagationResult {
        case inserted(RecordingEditableTextState)
        case originalNotInserted
        case originalNotInsertedAfterInteraction
        case canceledByUser
        case targetChanged
        case unavailable
    }

    var wasCanceledByUser: Bool {
        interactionCancellation.isCanceled
    }

    init?(
        target: RecordingInputTarget,
        preInsertionState: RecordingEditableTextState,
        insertedText: String,
        replacementText: String,
        clipboardOwnership: CursorPaster.ClipboardOwnership? = nil,
        startMonitoring: Bool = true,
        readState: @escaping ReadState = { RecordingInputTargetService.editableTextState(for: $0) },
        replaceText: @escaping ReplaceText = { target, range, replacement, expectedValue, caret, shouldCancel in
            RecordingInputTargetService.replaceTextValue(
                in: target,
                range: range,
                with: replacement,
                expectedCurrentValue: expectedValue,
                fallbackCaret: caret,
                shouldCancel: shouldCancel
            )
        },
        updateClipboard: @escaping UpdateClipboard = { ownership, text in
            CursorPaster.updateClipboardIfOwned(ownership, with: text)
        },
        onUserInteraction: @escaping @MainActor () -> Void
    ) {
        let source = preInsertionState.value as NSString
        let selectedRange = preInsertionState.selectedTextRange
        guard selectedRange.location >= 0,
            selectedRange.length >= 0,
            selectedRange.location <= source.length,
            selectedRange.length <= source.length - selectedRange.location
        else {
            return nil
        }

        let insertedLength = (insertedText as NSString).length
        let replacementLength = (replacementText as NSString).length
        guard replacementLength <= insertedLength,
            RecordingInputTargetService.isWithinEditableTextLimit(source.length),
            RecordingInputTargetService.isWithinEditableTextLimit(
                source.length - selectedRange.length + insertedLength
            )
        else { return nil }

        self.target = target
        self.preInsertionState = preInsertionState
        self.expectedPostInsertionValue = source.replacingCharacters(
            in: NSRange(location: selectedRange.location, length: selectedRange.length),
            with: insertedText
        )
        self.replacementRange = CFRange(location: selectedRange.location, length: replacementLength)
        self.expectedCaret = CFRange(location: selectedRange.location + insertedLength, length: 0)
        self.enhancedClipboardSuffix = (insertedText as NSString).substring(from: replacementLength)
        self.clipboardOwnership = clipboardOwnership
        self.readState = readState
        self.replaceText = replaceText
        self.updateClipboard = updateClipboard
        self.onUserInteraction = onUserInteraction

        if startMonitoring {
            guard beginMonitoringUserInteraction() else { return nil }
        }
    }

    deinit {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
    }

    func replace(
        with enhancedText: String,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> ReplacementResult {
        defer { stopMonitoring() }
        switch await observePastePropagation(
            verifyInsertionAfterUserInteraction: true,
            shouldCancel: shouldCancel
        ) {
        case .inserted(let currentState):
            let result = replaceIfUnchanged(
                enhancedText,
                currentState: currentState,
                shouldCancel: shouldCancel
            )
            if result == .replaced, let clipboardOwnership {
                _ = updateClipboard(clipboardOwnership, enhancedText + enhancedClipboardSuffix)
            }
            return result
        case .originalNotInserted:
            return .originalNotInserted
        case .originalNotInsertedAfterInteraction:
            return .originalNotInsertedAfterInteraction
        case .canceledByUser:
            return .canceledByUser
        case .targetChanged:
            return .targetChanged
        case .unavailable:
            return .unavailable
        }
    }

    /// Ends the transaction without replacing the raw text. Auto-send callers use this to verify
    /// that the target still contains the exact provisional value and caret after enhancement fails.
    func finishKeepingOriginal(
        verifyInsertionAfterCancellation: Bool = false,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> ReplacementResult {
        defer { stopMonitoring() }
        switch await observePastePropagation(
            verifyInsertionAfterCancellation: verifyInsertionAfterCancellation,
            shouldCancel: shouldCancel
        ) {
        case .inserted:
            return .originalRetained
        case .originalNotInserted:
            return .originalNotInserted
        case .originalNotInsertedAfterInteraction:
            return .originalNotInsertedAfterInteraction
        case .canceledByUser:
            return .canceledByUser
        case .targetChanged:
            return .targetChanged
        case .unavailable:
            return .unavailable
        }
    }

    func registerUserInteraction() {
        finishUserInteractionRegistration(shouldNotify: interactionCancellation.cancel())
    }

    func beginIgnoringPasteShortcut() {
        interactionCancellation.beginIgnoringPasteShortcut()
    }

    func endIgnoringPasteShortcut() {
        interactionCancellation.finishIgnoringPasteShortcut()
    }

    func setClipboardOwnership(_ clipboardOwnership: CursorPaster.ClipboardOwnership?) {
        self.clipboardOwnership = clipboardOwnership
    }

    private func finishUserInteractionRegistration(shouldNotify: Bool) {
        guard shouldNotify else { return }
        stopMonitoring()
        onUserInteraction()
    }

    func stopMonitoring() {
        guard let globalEventMonitor else { return }
        NSEvent.removeMonitor(globalEventMonitor)
        self.globalEventMonitor = nil
    }

    private func replaceIfUnchanged(
        _ enhancedText: String,
        currentState: RecordingEditableTextState,
        shouldCancel: @escaping @MainActor () -> Bool
    ) -> ReplacementResult {
        guard !shouldCancel(), !wasCanceledByUser, !Task.isCancelled else { return .canceledByUser }
        guard isExpectedPostInsertionState(currentState) else {
            return .targetChanged
        }

        let didReplace = replaceText(
            target,
            replacementRange,
            enhancedText,
            expectedPostInsertionValue,
            expectedCaret,
            { [interactionCancellation] in
                interactionCancellation.isCanceled || Task.isCancelled || shouldCancel()
            }
        )
        guard !shouldCancel() else { return .canceledByUser }
        if !didReplace {
            logger.notice("The provisional transcript target did not support a verified replacement")
        }
        return didReplace ? .replaced : .unavailable
    }

    private func isExactPreInsertionState(_ state: RecordingEditableTextState) -> Bool {
        state == preInsertionState
    }

    private func isExpectedPostInsertionState(_ state: RecordingEditableTextState) -> Bool {
        state.value == expectedPostInsertionValue
            && state.selectedTextRange.location == expectedCaret.location
            && state.selectedTextRange.length == expectedCaret.length
    }

    /// A fast enhancement (or failure) can complete before the target processes Cmd+V. Wait only
    /// while both the full value and selection remain at the exact pre-insertion snapshot.
    private func observePastePropagation(
        verifyInsertionAfterCancellation: Bool = false,
        verifyInsertionAfterUserInteraction: Bool = false,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> PastePropagationResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(300))
        while clock.now < deadline {
            guard !shouldCancel() else { return .canceledByUser }
            let wasCanceledByUser = self.wasCanceledByUser
            let wasCanceled = wasCanceledByUser || Task.isCancelled
            let shouldVerifyCancellation = verifyInsertionAfterCancellation
                || (verifyInsertionAfterUserInteraction && wasCanceledByUser)
            if wasCanceled && !shouldVerifyCancellation { return .canceledByUser }
            guard let currentState = readState(target) else { return .unavailable }
            guard !shouldCancel() else { return .canceledByUser }
            if isExpectedPostInsertionState(currentState) {
                return wasCanceled ? .canceledByUser : .inserted(currentState)
            }
            guard isExactPreInsertionState(currentState) else {
                return wasCanceled ? .canceledByUser : .targetChanged
            }
            if shouldVerifyCancellation {
                await waitIgnoringTaskCancellation(for: .milliseconds(20))
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return .canceledByUser
                }
            }
        }

        guard !shouldCancel() else { return .canceledByUser }
        let wasCanceledByUser = self.wasCanceledByUser
        let wasCanceled = wasCanceledByUser || Task.isCancelled
        let shouldVerifyCancellation = verifyInsertionAfterCancellation
            || (verifyInsertionAfterUserInteraction && wasCanceledByUser)
        if wasCanceled && !shouldVerifyCancellation { return .canceledByUser }
        guard let currentState = readState(target) else { return .unavailable }
        guard !shouldCancel() else { return .canceledByUser }
        if isExpectedPostInsertionState(currentState) {
            return wasCanceled ? .canceledByUser : .inserted(currentState)
        }
        guard isExactPreInsertionState(currentState) else {
            return wasCanceled ? .canceledByUser : .targetChanged
        }
        return wasCanceledByUser ? .originalNotInsertedAfterInteraction : .originalNotInserted
    }

    private func waitIgnoringTaskCancellation(for duration: Duration) async {
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
    }

    private func beginMonitoringUserInteraction() -> Bool {
        let mask: NSEvent.EventTypeMask = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .gesture,
        ]
        let cancellation = interactionCancellation
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard !cancellation.shouldIgnore(event) else { return }
            let shouldNotify = cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.finishUserInteractionRegistration(shouldNotify: shouldNotify)
            }
        }
        return globalEventMonitor != nil
    }
}
