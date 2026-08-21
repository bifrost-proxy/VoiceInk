import AppKit
import Foundation
import os

/// Owns one short-lived, in-memory transaction for replacing a raw transcript after enhancement.
/// The transaction fails closed: any user interaction or target-state mismatch leaves the raw text intact.
@MainActor
final class ProvisionalTextReplacementSession {
    enum ReplacementResult: Equatable {
        case replaced
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
        CFRange
    ) -> Bool

    private let target: RecordingInputTarget
    private let preInsertionState: RecordingEditableTextState
    private let expectedPostInsertionValue: String
    private let replacementRange: CFRange
    private let expectedCaret: CFRange
    private let readState: ReadState
    private let replaceText: ReplaceText
    private let onUserInteraction: @MainActor () -> Void
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "ProvisionalTextReplacement"
    )

    private var globalEventMonitor: Any?
    private(set) var wasCanceledByUser = false

    init?(
        target: RecordingInputTarget,
        preInsertionState: RecordingEditableTextState,
        insertedText: String,
        replacementText: String,
        startMonitoring: Bool = true,
        readState: @escaping ReadState = { RecordingInputTargetService.editableTextState(for: $0) },
        replaceText: @escaping ReplaceText = { target, range, replacement, expectedValue, caret in
            RecordingInputTargetService.replaceTextValue(
                in: target,
                range: range,
                with: replacement,
                expectedCurrentValue: expectedValue,
                fallbackCaret: caret
            )
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
        guard replacementLength <= insertedLength else { return nil }

        self.target = target
        self.preInsertionState = preInsertionState
        self.expectedPostInsertionValue = source.replacingCharacters(
            in: NSRange(location: selectedRange.location, length: selectedRange.length),
            with: insertedText
        )
        self.replacementRange = CFRange(location: selectedRange.location, length: replacementLength)
        self.expectedCaret = CFRange(location: selectedRange.location + insertedLength, length: 0)
        self.readState = readState
        self.replaceText = replaceText
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

    func replace(with enhancedText: String) async -> ReplacementResult {
        defer { stopMonitoring() }
        guard !wasCanceledByUser else { return .canceledByUser }

        // A very fast local enhancer can finish before the target application processes Cmd+V.
        // Briefly wait only while the control still has its exact pre-insertion state.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(300))
        while clock.now < deadline {
            guard !wasCanceledByUser else { return .canceledByUser }
            guard let currentState = readState(target) else { return .unavailable }

            if currentState.value == expectedPostInsertionValue {
                return replaceIfUnchanged(enhancedText, currentState: currentState)
            }
            guard currentState.value == preInsertionState.value else { return .targetChanged }
            try? await Task.sleep(for: .milliseconds(20))
        }

        guard !wasCanceledByUser else { return .canceledByUser }
        guard let currentState = readState(target) else { return .unavailable }
        return replaceIfUnchanged(enhancedText, currentState: currentState)
    }

    func registerUserInteraction() {
        guard !wasCanceledByUser else { return }
        wasCanceledByUser = true
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
        currentState: RecordingEditableTextState
    ) -> ReplacementResult {
        guard !wasCanceledByUser else { return .canceledByUser }
        guard currentState.value == expectedPostInsertionValue,
            currentState.selectedTextRange.location == expectedCaret.location,
            currentState.selectedTextRange.length == expectedCaret.length
        else {
            return .targetChanged
        }

        let didReplace = replaceText(
            target,
            replacementRange,
            enhancedText,
            expectedPostInsertionValue,
            expectedCaret
        )
        if !didReplace {
            logger.notice("The provisional transcript target did not support a verified replacement")
        }
        return didReplace ? .replaced : .unavailable
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
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.registerUserInteraction()
            }
        }
        return globalEventMonitor != nil
    }
}
