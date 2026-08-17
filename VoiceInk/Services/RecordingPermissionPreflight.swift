import AppKit
import ApplicationServices
import CoreGraphics

enum RecordingPermissionIssue: Equatable {
    case microphone
    case accessibility
    case screenRecording

    var notificationTitle: String {
        switch self {
        case .microphone:
            return String(localized: "Microphone permission is required to record")
        case .accessibility:
            return String(localized: "Accessibility permission is required for recording shortcuts")
        case .screenRecording:
            return String(localized: "Screen Recording permission is required for this mode")
        }
    }

    var settingsPane: PrivacySettingsPane {
        switch self {
        case .microphone:
            return .microphone
        case .accessibility:
            return .accessibility
        case .screenRecording:
            return .screenRecording
        }
    }
}

enum RecordingPermissionRequirements {
    static func firstMissingPermission(
        hasMicrophonePermission: Bool,
        hasAccessibilityPermission: Bool,
        hasScreenRecordingPermission: Bool,
        requiresScreenRecording: Bool
    ) -> RecordingPermissionIssue? {
        if !hasMicrophonePermission {
            return .microphone
        }
        if !hasAccessibilityPermission {
            return .accessibility
        }
        if requiresScreenRecording, !hasScreenRecordingPermission {
            return .screenRecording
        }
        return nil
    }
}

@MainActor
enum RecordingPermissionPreflight {
    static func checkContextPermissions(requiresScreenRecording: Bool) async
        -> RecordingPermissionIssue?
    {
        if !AXIsProcessTrusted() {
            requestAccessibilityPermission()
            return .accessibility
        }

        if requiresScreenRecording, !CGPreflightScreenCaptureAccess() {
            let granted = await ScreenCaptureService.requestScreenCapturePermissionRegistration()
            if !granted {
                openSettings(for: .screenRecording)
                return .screenRecording
            }
        }

        return nil
    }

    static func handleDeniedMicrophonePermission() {
        openSettings(for: .microphone)
    }

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(for: .accessibility)
    }

    static func openSettings(for issue: RecordingPermissionIssue) {
        guard let url = URL(string: issue.settingsPane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
