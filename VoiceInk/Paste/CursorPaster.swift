import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    struct ClipboardOwnership: Equatable, Sendable {
        let sessionID: String
        let changeCount: Int
        let expectedText: String
    }

    struct PasteResult: Equatable, Sendable {
        let didPostCommand: Bool
        let clipboardOwnership: ClipboardOwnership?

        static let commandPosted = PasteResult(didPostCommand: true, clipboardOwnership: nil)
        static let commandNotPosted = PasteResult(didPostCommand: false, clipboardOwnership: nil)
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(text)
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(
        _ text: String,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> PasteResult {
        await performPasteSession(text, shouldCancel: shouldCancel)
    }

    @MainActor
    private static func performPasteSession(
        _ text: String,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> PasteResult {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        // Even when the user normally keeps pasted text on the clipboard, an aborted paste must
        // put back the contents that VoiceInk temporarily replaced. Otherwise canceling before
        // Cmd+V is emitted destroys the user's clipboard without delivering any text.
        let savedContents = snapshotClipboard(from: pasteboard)
        let sessionID = UUID().uuidString

        guard
            ClipboardManager.setClipboard(
                text,
                transient: shouldRestoreClipboard,
                sessionID: sessionID
            )
        else {
            logger.error("Failed to prepare clipboard for paste")
            restoreClipboard(savedContents, on: pasteboard)
            return .commandNotPosted
        }
        let clipboardChangeCount = pasteboard.changeCount

        await wait(prePasteDelay)

        guard !shouldCancel() else {
            restoreClipboardIfOwned(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
            return .commandNotPosted
        }

        let pasteResult = await postPasteCommand(shouldCancel: shouldCancel)
        guard pasteResult.didPostCommand else {
            restoreClipboardIfOwned(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
            return .commandNotPosted
        }
        if shouldRestoreClipboard {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        return PasteResult(
            didPostCommand: true,
            clipboardOwnership: shouldRestoreClipboard ? nil : ClipboardOwnership(
                sessionID: sessionID,
                changeCount: clipboardChangeCount,
                expectedText: text
            )
        )
    }

    /// Updates the persistent clipboard after an AX-only provisional replacement, but only while
    /// no other application or user action has changed the pasteboard since VoiceInk prepared it.
    @MainActor
    static func updateClipboardIfOwned(
        _ ownership: ClipboardOwnership,
        with text: String
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        guard stillOwnsClipboard(
            ownership,
            changeCount: pasteboard.changeCount,
            text: pasteboard.string(forType: .string),
            sessionID: pasteboard.string(forType: ClipboardManager.pasteSessionType)
        ) else {
            return false
        }
        return ClipboardManager.setClipboard(text, transient: false, sessionID: ownership.sessionID)
    }

    static func stillOwnsClipboard(
        _ ownership: ClipboardOwnership,
        changeCount: Int,
        text: String?,
        sessionID: String?
    ) -> Bool {
        changeCount == ownership.changeCount
            && text == ownership.expectedText
            && sessionID == ownership.sessionID
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand(
        shouldCancel: @escaping @MainActor () -> Bool
    ) async -> PasteResult {
        guard !shouldCancel() else { return .commandNotPosted }
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard(shouldCancel: shouldCancel)
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            restoreClipboardIfOwned(
                savedContents,
                expectedText: expectedText,
                sessionID: sessionID,
                on: pasteboard
            )
        }
    }

    private static func restoreClipboardIfOwned(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        guard pasteboardStillOwnedByPasteSession(
            pasteboard,
            expectedText: expectedText,
            sessionID: sessionID
        ) else {
            return
        }
        restoreClipboard(savedContents, on: pasteboard)
    }

    private static func restoreClipboard(
        _ savedContents: ClipboardSnapshot,
        on pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        if !savedContents.isEmpty {
            pasteboard.writeObjects(pasteboardItems(from: savedContents))
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard(
        shouldCancel: @escaping @MainActor () -> Bool
    ) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        guard !shouldCancel() else { return .commandNotPosted }

        var commandIsDown = true
        var pasteKeyIsDown = false
        defer {
            // A cancellation can stop the shortcut before V is emitted, but any already-posted
            // key-down events must always be balanced so Command never remains logically stuck.
            if pasteKeyIsDown {
                vUp.post(tap: .cghidEventTap)
            }
            if commandIsDown {
                cmdUp.post(tap: .cghidEventTap)
            }
        }

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        guard !shouldCancel() else { return .commandNotPosted }

        vDown.post(tap: .cghidEventTap)
        pasteKeyIsDown = true
        await wait(pasteShortcutEventDelay)
        if shouldCancel() {
            return .commandPosted
        }

        vUp.post(tap: .cghidEventTap)
        pasteKeyIsDown = false
        await wait(pasteShortcutEventDelay)
        if shouldCancel() {
            return .commandPosted
        }

        cmdUp.post(tap: .cghidEventTap)
        commandIsDown = false

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Auto Send Keys

    static func performAutoSend(_ key: AutoSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
