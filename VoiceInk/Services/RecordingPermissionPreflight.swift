import AppKit
import ApplicationServices
import AVFoundation
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

enum RecorderPermissionGuidance: Equatable {
    case required(RecordingPermissionIssue)
    case ready

    var title: String {
        switch self {
        case .required(let issue):
            return issue.guidanceTitle
        case .ready:
            return String(localized: "Permissions Are Ready")
        }
    }

    var message: String {
        switch self {
        case .required(let issue):
            return issue.guidanceMessage
        case .ready:
            return String(localized: "Press your shortcut again or select Start Recording below.")
        }
    }

    var actionTitle: String {
        switch self {
        case .required:
            return String(localized: "Open System Settings")
        case .ready:
            return String(localized: "Start Recording")
        }
    }

    var systemImage: String {
        switch self {
        case .required:
            return "exclamationmark.shield.fill"
        case .ready:
            return "checkmark.shield.fill"
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
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return true
            case .notDetermined:
                let isGranted = await AVCaptureDevice.requestAccess(for: .audio)
                if !isGranted {
                    openSettings(for: issue)
                }
                return isGranted
            case .denied, .restricted:
                openSettings(for: issue)
                return false
            @unknown default:
                openSettings(for: issue)
                return false
            }
        case .accessibility:
            guard !AXIsProcessTrusted() else { return true }
            requestAccessibilityPermission()
            return AXIsProcessTrusted()
        case .screenRecording:
            guard !CGPreflightScreenCaptureAccess() else { return true }
            let isGranted = await ScreenCaptureService.requestScreenCapturePermissionRegistration()
            if !isGranted {
                openSettings(for: issue)
            }
            return isGranted
        }
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
