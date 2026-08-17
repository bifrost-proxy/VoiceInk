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

    @Test func recorderGuidanceAlwaysProvidesAnActionableNextStep() {
        let accessibility = RecorderPermissionGuidance.required(.accessibility)
        let ready = RecorderPermissionGuidance.ready

        #expect(!accessibility.title.isEmpty)
        #expect(!accessibility.message.isEmpty)
        #expect(!accessibility.actionTitle.isEmpty)
        #expect(accessibility.systemImage == "exclamationmark.shield.fill")
        #expect(!ready.title.isEmpty)
        #expect(!ready.message.isEmpty)
        #expect(!ready.actionTitle.isEmpty)
        #expect(ready.systemImage == "checkmark.shield.fill")
    }
}
