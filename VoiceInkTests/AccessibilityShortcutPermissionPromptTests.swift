import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct AccessibilityShortcutPermissionPromptTests {
    @Test func presentsWhenAccessibilityIsMissing() {
        #expect(
            AccessibilityShortcutPermissionPrompt.shouldPresent(
                isTrusted: false,
                now: Date(timeIntervalSince1970: 100),
                lastPresentedAt: nil,
                cooldown: 600
            )
        )
    }

    @Test func neverPresentsWhenAccessibilityIsGranted() {
        #expect(
            !AccessibilityShortcutPermissionPrompt.shouldPresent(
                isTrusted: true,
                now: Date(timeIntervalSince1970: 1_000),
                lastPresentedAt: nil,
                cooldown: 600
            )
        )
    }

    @Test func throttlesRepeatedMissingPermissionPrompts() {
        let lastPresentedAt = Date(timeIntervalSince1970: 100)

        #expect(
            !AccessibilityShortcutPermissionPrompt.shouldPresent(
                isTrusted: false,
                now: Date(timeIntervalSince1970: 699),
                lastPresentedAt: lastPresentedAt,
                cooldown: 600
            )
        )
        #expect(
            AccessibilityShortcutPermissionPrompt.shouldPresent(
                isTrusted: false,
                now: Date(timeIntervalSince1970: 700),
                lastPresentedAt: lastPresentedAt,
                cooldown: 600
            )
        )
    }
}
