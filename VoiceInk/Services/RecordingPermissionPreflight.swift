import ApplicationServices
import AVFoundation
import CoreGraphics

enum RecordingPermissionIssue: Equatable {
    case microphone
    case accessibility
    case screenRecording

    var guidanceTitle: String {
        switch self {
        case .microphone:
            return String(localized: "Allow Microphone Access")
        case .accessibility:
            return String(localized: "Allow Accessibility Access")
        case .screenRecording:
            return String(localized: "Allow Screen Recording Access")
        }
    }

    var guidanceMessage: String {
        switch self {
        case .microphone:
            return String(
                localized:
                    "VoiceInk needs microphone access before it can record. Allow VoiceInk in System Settings, then return here."
            )
        case .accessibility:
            return String(
                localized:
                    "VoiceInk needs Accessibility access to detect shortcuts and type transcriptions. Enable VoiceInk in System Settings, then return here."
            )
        case .screenRecording:
            return String(
                localized:
                    "This mode uses screen context. Allow VoiceInk under Screen & System Audio Recording, then return here. macOS may require VoiceInk to restart."
            )
        }
    }
}

enum RecorderPermissionGuidance: Equatable {
    case required(RecordingPermissionIssue)
    case requesting(RecordingPermissionIssue)
    case ready

    var title: String {
        switch self {
        case .required(let issue), .requesting(let issue):
            return issue.guidanceTitle
        case .ready:
            return String(localized: "Permissions Are Ready")
        }
    }

    var message: String {
        switch self {
        case .required(let issue):
            return issue.guidanceMessage
        case .requesting:
            return String(
                localized:
                    "Complete the macOS permission request. VoiceInk will stay responsive while it waits."
            )
        case .ready:
            return String(localized: "Press your shortcut again or select Start Recording below.")
        }
    }

    var actionTitle: String {
        switch self {
        case .required:
            return String(localized: "Open System Settings")
        case .requesting:
            return String(localized: "Waiting for Permission…")
        case .ready:
            return String(localized: "Start Recording")
        }
    }

    var systemImage: String {
        switch self {
        case .required:
            return "exclamationmark.shield.fill"
        case .requesting:
            return "clock.badge.checkmark"
        case .ready:
            return "checkmark.shield.fill"
        }
    }

    var isActionEnabled: Bool {
        if case .requesting = self {
            return false
        }
        return true
    }

    var issue: RecordingPermissionIssue? {
        switch self {
        case .required(let issue), .requesting(let issue):
            return issue
        case .ready:
            return nil
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
    static func firstMissingPermission(requiresScreenRecording: Bool) -> RecordingPermissionIssue? {
        RecordingPermissionRequirements.firstMissingPermission(
            hasMicrophonePermission: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            hasAccessibilityPermission: AXIsProcessTrusted(),
            hasScreenRecordingPermission: CGPreflightScreenCaptureAccess(),
            requiresScreenRecording: requiresScreenRecording
        )
    }

    static func requestAuthorization(for issue: RecordingPermissionIssue) async -> Bool {
        switch issue {
        case .microphone:
            return await PrivacyPermissionAuthorizationService.requestMicrophoneAuthorization()
        case .accessibility:
            return await PrivacyPermissionAuthorizationService.requestAccessibilityAuthorization()
        case .screenRecording:
            return await PrivacyPermissionAuthorizationService.requestScreenRecordingAuthorization()
        }
    }
}
