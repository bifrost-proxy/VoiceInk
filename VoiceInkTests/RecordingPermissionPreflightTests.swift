import AppKit
import Carbon.HIToolbox
import Testing

@testable import VoiceInk

@MainActor
struct RecordingPermissionPreflightTests {
    @Test func microphonePermissionHasHighestPriority() {
        #expect(
            RecordingPermissionRequirements.firstMissingPermission(
                hasMicrophonePermission: false,
                hasAccessibilityPermission: false,
                hasScreenRecordingPermission: false,
                requiresScreenRecording: true
            ) == .microphone
        )
    }

    @Test func accessibilityPermissionIsRequiredForRecordingShortcuts() {
        #expect(
            RecordingPermissionRequirements.firstMissingPermission(
                hasMicrophonePermission: true,
                hasAccessibilityPermission: false,
                hasScreenRecordingPermission: true,
                requiresScreenRecording: true
            ) == .accessibility
        )
    }

    @Test func screenRecordingIsRequiredOnlyWhenModeUsesScreenContext() {
        #expect(
            RecordingPermissionRequirements.firstMissingPermission(
                hasMicrophonePermission: true,
                hasAccessibilityPermission: true,
                hasScreenRecordingPermission: false,
                requiresScreenRecording: true
            ) == .screenRecording
        )
        #expect(
            RecordingPermissionRequirements.firstMissingPermission(
                hasMicrophonePermission: true,
                hasAccessibilityPermission: true,
                hasScreenRecordingPermission: false,
                requiresScreenRecording: false
            ) == nil
        )
    }

    @Test func carbonFallbackMapsShortcutModifiers() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
        let expected = UInt32(controlKey | optionKey | shiftKey | cmdKey | kEventKeyModifierFnMask)

        #expect(AccessibilityShortcutFallbackMonitor.carbonModifiers(for: flags) == expected)
    }
}
