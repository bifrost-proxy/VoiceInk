import ApplicationServices
import Foundation

/// Presents one actionable explanation when global shortcut monitoring cannot
/// start because VoiceInk is not trusted for Accessibility. The event tap never
/// receives the user's shortcut in that state, so the prompt must happen while
/// installing the monitor rather than inside a key callback.
@MainActor
enum AccessibilityShortcutPermissionPrompt {
    static let presentationCooldown: TimeInterval = 600
    private static var lastPresentedAt: Date?

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

    private static func requestAuthorizationAndOpenSettings() {
        Task { @MainActor in
            _ = await PrivacyPermissionAuthorizationService.requestAccessibilityAuthorization()
        }
    }
}
