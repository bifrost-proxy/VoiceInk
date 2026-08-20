import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import SwiftUI

enum OnboardingStage: String, CaseIterable {
    case permissions
    case microphone
    case model
    case api
    case experience
    case contextAwareness
    case trust

    var stepNumber: Int {
        switch self {
        case .permissions:
            return 1
        case .microphone:
            return 2
        case .model:
            return 3
        case .api:
            return 4
        case .experience:
            return 5
        case .contextAwareness:
            return 6
        case .trust:
            return 7
        }
    }

    var systemImage: String {
        switch self {
        case .permissions:
            return "lock.shield"
        case .microphone:
            return "mic"
        case .model:
            return "captions.bubble"
        case .api:
            return "checkmark.seal"
        case .experience:
            return "square.grid.2x2.fill"
        case .contextAwareness:
            return "slider.horizontal.3"
        case .trust:
            return "lock.shield"
        }
    }

    var title: String {
        switch self {
        case .permissions:
            return String(localized: "Allow Permissions")
        case .microphone:
            return String(localized: "Choose Microphone")
        case .model:
            return String(localized: "Configure Transcription Model")
        case .api:
            return String(localized: "Verify API Key")
        case .experience:
            return String(localized: "Experience VoiceInk")
        case .contextAwareness:
            return String(localized: "VoiceInk is Context-Aware")
        case .trust:
            return String(localized: "VoiceInk is Open Source")
        }
    }

    var subtitle: String {
        switch self {
        case .permissions:
            return String(localized: "Allow VoiceInk to work across all your apps.")
        case .microphone:
            return String(localized: "Pick the microphone VoiceInk should use for recordings.")
        case .model:
            return String(localized: "Use NVIDIA's Parakeet model locally, or connect a cloud transcription provider.")
        case .api:
            return String(
                localized:
                    "VoiceInk uses LLMs to enhance transcripts and perform AI actions. Set up an API key before continuing."
            )
        case .experience:
            return String(localized: "Try a few short samples and see how VoiceInk works before you start.")
        case .contextAwareness:
            return String(
                localized: "VoiceInk can select the right mode from the app you are using and the rules you configure.")
        case .trust:
            return String(localized: "VoiceInk is private by default. No data leaves your device unless you opt in.")
        }
    }

    static var baseStepCount: Int {
        4
    }
}

enum OnboardingPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording

    var id: String { rawValue }

    static var required: [OnboardingPermissionKind] {
        [.microphone, .accessibility]
    }

    var isRequired: Bool {
        Self.required.contains(self)
    }

    var descriptor: OnboardingPermissionDescriptor {
        switch self {
        case .microphone:
            return OnboardingPermissionDescriptor(
                title: "Microphone",
                subtitle: String(localized: "VoiceInk uses your microphone to capture your voice.")
            )

        case .accessibility:
            return OnboardingPermissionDescriptor(
                title: String(localized: "Accessibility"),
                subtitle: String(localized: "VoiceInk uses Accessibility to type transcriptions directly into any app.")
            )

        case .screenRecording:
            return OnboardingPermissionDescriptor(
                title: String(localized: "Screen Recording"),
                subtitle: String(
                    localized: "VoiceInk reads visible screen content to improve the accuracy of transcripts.")
            )
        }
    }
}

struct OnboardingPermissionDescriptor {
    let title: String
    let subtitle: String
}

enum OnboardingPermissionStatus: Equatable {
    case granted
    case needsAccess
    case denied
    case restricted
    case unknown

    var isGranted: Bool {
        self == .granted
    }

    var requiresSettings: Bool {
        self == .denied || self == .restricted
    }

    var label: String {
        switch self {
        case .granted:
            return String(localized: "Granted")
        case .needsAccess:
            return String(localized: "Needs access")
        case .denied:
            return String(localized: "Denied")
        case .restricted:
            return String(localized: "Restricted")
        case .unknown:
            return String(localized: "Unknown")
        }
    }

    var color: Color {
        switch self {
        case .granted:
            return AppTheme.Text.secondary
        case .needsAccess:
            return AppTheme.Text.secondary
        case .denied, .restricted:
            return AppTheme.Status.error
        case .unknown:
            return AppTheme.Text.secondary
        }
    }
}

enum PrivacySettingsPane: Sendable {
    case microphone
    case accessibility
    case screenRecording

    var urlString: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }

    var tccService: String? {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "ScreenCapture"
        }
    }
}

struct PrivacyPermissionResetCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

enum PrivacyPermissionResetService {
    static func command(
        for pane: PrivacySettingsPane,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.prakashjoshipax.VoiceInk"
    ) -> PrivacyPermissionResetCommand? {
        guard let tccService = pane.tccService else { return nil }

        return PrivacyPermissionResetCommand(
            executable: "/usr/bin/tccutil",
            arguments: ["reset", tccService, bundleIdentifier]
        )
    }

    /// Removes a stale TCC entry before the current VoiceInk build asks macOS to
    /// register itself again. Community releases use an ad-hoc signature, so a
    /// record left by an older build cannot be reused reliably after an update.
    static func resetAuthorization(for pane: PrivacySettingsPane) async -> String? {
        guard let command = command(for: pane) else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.standardOutput = Pipe()
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                let detail = error.localizedDescription
                NSLog("VoiceInk permission reset failed to start: %@", detail)
                return detail
            }

            guard process.terminationStatus == 0 else {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail?.isEmpty == false
                    ? detail!
                    : "tccutil exited with status \(process.terminationStatus)"
                NSLog("VoiceInk permission reset failed: %@", message)
                return message
            }

            return nil
        }.value
    }
}

enum PrivacyPermissionAuthorizationAction: Equatable {
    case alreadyGranted
    case request
    case openSettings
}

@MainActor
struct PrivacyPaneAuthorizationRequestDependencies {
    let hasAccess: () -> Bool
    let resetAuthorization: () async -> String?
    let registerCurrentApplication: () async -> Bool
    let openSettings: () -> Void

    static let accessibilityLive = PrivacyPaneAuthorizationRequestDependencies(
        hasAccess: {
            AXIsProcessTrusted()
        },
        resetAuthorization: {
            await PrivacyPermissionResetService.resetAuthorization(for: .accessibility)
        },
        registerCurrentApplication: {
            let options: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ]
            return AXIsProcessTrustedWithOptions(options)
        },
        openSettings: {
            guard let url = URL(string: PrivacySettingsPane.accessibility.urlString) else { return }
            NSWorkspace.shared.open(url)
        }
    )

    static let screenRecordingLive = PrivacyPaneAuthorizationRequestDependencies(
        hasAccess: {
            CGPreflightScreenCaptureAccess()
        },
        resetAuthorization: {
            await PrivacyPermissionResetService.resetAuthorization(for: .screenRecording)
        },
        registerCurrentApplication: {
            await ScreenCaptureService.requestScreenCapturePermissionRegistration()
        },
        openSettings: {
            guard let url = URL(string: PrivacySettingsPane.screenRecording.urlString) else { return }
            NSWorkspace.shared.open(url)
        }
    )
}

enum PrivacyPermissionAuthorizationService {
    static func microphoneAction(
        for status: AVAuthorizationStatus
    ) -> PrivacyPermissionAuthorizationAction {
        switch status {
        case .authorized:
            return .alreadyGranted
        case .notDetermined:
            return .request
        case .denied, .restricted:
            return .openSettings
        @unknown default:
            return .openSettings
        }
    }

    static func accessibilityAction(isTrusted: Bool) -> PrivacyPermissionAuthorizationAction {
        isTrusted ? .alreadyGranted : .request
    }

    static func screenRecordingAction(hasAccess: Bool) -> PrivacyPermissionAuthorizationAction {
        hasAccess ? .alreadyGranted : .request
    }

    @MainActor
    static func requestMicrophoneAuthorization(openSettingsWhenNeeded: Bool = true) async -> Bool {
        let action = microphoneAction(for: AVCaptureDevice.authorizationStatus(for: .audio))
        let isGranted: Bool

        switch action {
        case .alreadyGranted:
            return true
        case .request:
            isGranted = await AVCaptureDevice.requestAccess(for: .audio)
        case .openSettings:
            isGranted = false
        }

        if !isGranted,
            openSettingsWhenNeeded,
            let url = URL(string: PrivacySettingsPane.microphone.urlString)
        {
            NSWorkspace.shared.open(url)
        }

        return isGranted
    }

    @MainActor
    static func requestAccessibilityAuthorization(
        openSettings: Bool = true,
        dependencies: PrivacyPaneAuthorizationRequestDependencies? = nil
    ) async -> Bool {
        let dependencies = dependencies ?? .accessibilityLive
        return await requestPrivacyPaneAuthorization(
            openSettings: openSettings,
            permissionName: "Accessibility",
            dependencies: dependencies
        )
    }

    @MainActor
    static func requestScreenRecordingAuthorization(
        openSettingsWhenNeeded: Bool = true,
        dependencies: PrivacyPaneAuthorizationRequestDependencies? = nil
    ) async -> Bool {
        let dependencies = dependencies ?? .screenRecordingLive
        return await requestPrivacyPaneAuthorization(
            openSettings: openSettingsWhenNeeded,
            permissionName: "Screen Recording",
            dependencies: dependencies
        )
    }

    @MainActor
    private static func requestPrivacyPaneAuthorization(
        openSettings: Bool,
        permissionName: String,
        dependencies: PrivacyPaneAuthorizationRequestDependencies
    ) async -> Bool {
        guard !dependencies.hasAccess() else { return true }

        if openSettings, let resetError = await dependencies.resetAuthorization() {
            NSLog("VoiceInk could not clear the stale %@ permission: %@", permissionName, resetError)
        }

        // Reset first, then prompt macOS so System Settings contains the current
        // app build instead of the obsolete ad-hoc-signed entry.
        let isGranted = await dependencies.registerCurrentApplication()

        if !isGranted, openSettings {
            dependencies.openSettings()
        }

        return isGranted
    }
}
