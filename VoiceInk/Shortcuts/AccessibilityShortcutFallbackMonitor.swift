import AppKit
import Carbon.HIToolbox
import Foundation

/// Carbon hot keys remain available when the Accessibility-protected CGEventTap
/// cannot be installed. They only guide the user to permissions; recording is
/// still handled by ShortcutMonitor after Accessibility access is granted.
@MainActor
final class AccessibilityShortcutFallbackMonitor {
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private let onShortcutAttempt: @MainActor () -> Void

    init(onShortcutAttempt: @escaping @MainActor () -> Void) {
        self.onShortcutAttempt = onShortcutAttempt
    }

    @discardableResult
    func start(shortcuts: [Shortcut]) -> Int {
        stop()

        let keyShortcuts = shortcuts.filter { !$0.isModifierOnly }
        guard !keyShortcuts.isEmpty else { return 0 }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let monitor = Unmanaged<AccessibilityShortcutFallbackMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    monitor.onShortcutAttempt()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else { return 0 }

        let signature = Self.fourCharacterCode("VIKP")
        for (index, shortcut) in keyShortcuts.enumerated() {
            var hotKey: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                Self.carbonModifiers(for: shortcut.modifierFlags),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            }
        }

        if hotKeys.isEmpty {
            stop()
        }
        return hotKeys.count
    }

    func stop() {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.function) { modifiers |= UInt32(kEventKeyModifierFnMask) }
        return modifiers
    }

    private static func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { result, byte in
            (result << 8) + OSType(byte)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}
