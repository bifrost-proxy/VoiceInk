import AppKit
import ApplicationServices
import Foundation

/// Presents one actionable explanation when global shortcut monitoring cannot
/// start because VoiceInk is not trusted for Accessibility. The event tap never
/// receives the user's shortcut in that state, so the prompt must happen while
/// installing the monitor rather than inside a key callback.
@MainActor
enum AccessibilityShortcutPermissionPrompt {
    static let presentationCooldown: TimeInterval = 600
    static let shortcutAttemptCooldown: TimeInterval = 2
    private static var lastPresentedAt: Date?
    private static var lastShortcutAttemptAt: Date?

    @discardableResult
    static func showIfNeeded(now: Date = Date()) -> Bool {
        let isTrusted = AXIsProcessTrusted()
        guard shouldPresent(
            isTrusted: isTrusted,
            now: now,
            lastPresentedAt: lastPresentedAt,
            cooldown: presentationCooldown
        ) else {
            return false
        }

        lastPresentedAt = now
        NotificationManager.shared.showNotification(
            title: String(localized: "Accessibility permission is not provided"),
            type: .warning,
            duration: 10,
            actionButton: (
                String(localized: "Open Settings"),
                requestAuthorizationAndOpenSettings
            )
        )
        return true
    }

    /// Called by the Carbon fallback when CGEventTap cannot receive the user's
    /// shortcut. Unlike the launch reminder, this also opens System Settings.
    @discardableResult
    static func showForShortcutAttempt(now: Date = Date()) -> Bool {
        let isTrusted = AXIsProcessTrusted()
        guard shouldPresent(
            isTrusted: isTrusted,
            now: now,
            lastPresentedAt: lastShortcutAttemptAt,
            cooldown: shortcutAttemptCooldown
        ) else {
            return false
        }

        lastShortcutAttemptAt = now
        presentNotification()
        requestAuthorizationAndOpenSettings()
        return true
    }

    static func shouldPresent(
        isTrusted: Bool,
        now: Date,
        lastPresentedAt: Date?,
        cooldown: TimeInterval
    ) -> Bool {
        guard !isTrusted else { return false }
        guard let lastPresentedAt else { return true }
        return now.timeIntervalSince(lastPresentedAt) >= cooldown
    }

    private static func presentNotification() {
        NotificationManager.shared.showNotification(
            title: String(localized: "Accessibility permission is not provided"),
            type: .warning,
            duration: 10,
            actionButton: (
                String(localized: "Open Settings"),
                requestAuthorizationAndOpenSettings
            )
        )
    }

    private static func requestAuthorizationAndOpenSettings() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)

        guard let url = URL(string: PrivacySettingsPane.accessibility.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
