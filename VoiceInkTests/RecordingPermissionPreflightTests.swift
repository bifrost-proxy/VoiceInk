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

    @Test func carbonFallbackCannotRegisterModifierOnlyShortcuts() {
        let keyShortcut = Shortcut.key(keyCode: 1, modifierFlags: [.command])
        let modifierShortcut = Shortcut.rightCommand

        #expect(
            AccessibilityShortcutFallbackMonitor.eligibleShortcuts(
                from: [modifierShortcut, keyShortcut]
            ) == [keyShortcut]
        )
    }

    @Test func modifierOnlyRecordingShortcutRequiresProactiveGuidance() {
        let modifierShortcut = Shortcut.rightCommand
        let unrelatedKeyShortcut = Shortcut.key(keyCode: 1, modifierFlags: [.command])

        #expect(
            RecordingShortcutManager.needsProactiveAccessibilityGuidance(
                recordingShortcuts: [modifierShortcut],
                configuredShortcutCount: 2,
                registeredFallbackCount: 1
            )
        )
        #expect(
            !RecordingShortcutManager.needsProactiveAccessibilityGuidance(
                recordingShortcuts: [unrelatedKeyShortcut],
                configuredShortcutCount: 1,
                registeredFallbackCount: 1
            )
        )
    }

    @Test func missingAccessibilityUsesOnlyOnePermissionSurface() {
        let modifierShortcut = Shortcut.rightCommand
        let keyShortcut = Shortcut.key(keyCode: 1, modifierFlags: [.command])

        #expect(
            RecordingShortcutManager.missingAccessibilityPresentation(
                isRecorderGuidancePresented: true,
                recordingShortcuts: [modifierShortcut],
                configuredShortcutCount: 1,
                registeredFallbackCount: 0
            ) == .suppressed
        )
        #expect(
            RecordingShortcutManager.missingAccessibilityPresentation(
                isRecorderGuidancePresented: false,
                recordingShortcuts: [modifierShortcut],
                configuredShortcutCount: 1,
                registeredFallbackCount: 0
            ) == .recorderGuidance
        )
        #expect(
            RecordingShortcutManager.missingAccessibilityPresentation(
                isRecorderGuidancePresented: false,
                recordingShortcuts: [keyShortcut],
                configuredShortcutCount: 1,
                registeredFallbackCount: 1
            ) == .standalonePrompt
        )
    }

    @Test func screenPermissionRequestDoesNotBlockMainActor() async throws {
        let startedAt = Date()
        let permissionTask = Task { @MainActor in
            await ScreenCaptureService.performPermissionRequest {
                Thread.sleep(forTimeInterval: 0.2)
                return true
            }
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        #expect(Date().timeIntervalSince(startedAt) < 0.15)
        #expect(await permissionTask.value)
    }

    @Test func recorderGuidanceAlwaysProvidesAnActionableNextStep() {
        let accessibility = RecorderPermissionGuidance.required(.accessibility)
        let requesting = RecorderPermissionGuidance.requesting(.screenRecording)
        let ready = RecorderPermissionGuidance.ready

        #expect(!accessibility.title.isEmpty)
        #expect(!accessibility.message.isEmpty)
        #expect(!accessibility.actionTitle.isEmpty)
        #expect(accessibility.systemImage == "exclamationmark.shield.fill")
        #expect(accessibility.isActionEnabled)
        #expect(requesting.issue == .screenRecording)
        #expect(!requesting.isActionEnabled)
        #expect(!requesting.message.isEmpty)
        #expect(!requesting.actionTitle.isEmpty)
        #expect(!ready.title.isEmpty)
        #expect(!ready.message.isEmpty)
        #expect(!ready.actionTitle.isEmpty)
        #expect(ready.systemImage == "checkmark.shield.fill")
    }
}
