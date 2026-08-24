import LaunchAtLogin
import OSLog
import SwiftUI

struct MenuBarView: View {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MenuBarWindowFlow")

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var updater = UpdateManager.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                showMainWindow(reason: "Complete Onboarding")
            }

            Divider()

            updateMenuItem

            Divider()

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button("Toggle Recorder") {
                recorderUIManager.handleToggleRecorderPanelNotification()
            }

            Divider()

            Menu {
                ForEach(modeManager.enabledConfigurations) { config in
                    Button {
                        modeManager.setActiveConfiguration(config)
                    } label: {
                        let isActive = modeManager.currentEffectiveConfiguration?.id == config.id
                        Text(isActive ? "\(config.name)  ✓" : config.name)
                    }
                }

                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Manage Modes") {
                    showMainWindowAndNavigate(to: "Modes", reason: "Manage Modes")
                }

                Button("Manage Models") {
                    showMainWindowAndNavigate(to: "AI Models", reason: "Manage Models")
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles.square.fill.on.square")
                        .font(.system(size: 11, weight: .medium))
                    let activeMode = modeManager.currentEffectiveConfiguration
                    Text(String(format: String(localized: "Mode: %@"), activeMode?.name ?? String(localized: "None")))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Menu {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Button {
                        audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                    } label: {
                        let isActive = audioDeviceManager.getCurrentDevice() == device.id
                        Text(isActive ? "\(device.name)  ✓" : device.name)
                    }
                }

                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("Audio Input")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }

            Button("History") {
                menuBarManager.openHistoryWindow()
            }

            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                let shouldShowMainWindow = menuBarManager.isMenuBarOnly
                menuBarManager.toggleMenuBarOnly()

                if shouldShowMainWindow {
                    showMainWindow(reason: "Show Dock Icon")
                }
            }

            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { oldValue, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }

            Divider()

            Button("Settings") {
                showMainWindowAndNavigate(to: "Settings", reason: "Settings")
            }
            .keyboardShortcut(",", modifiers: .command)

            updateMenuItem

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var updateMenuItem: some View {
        switch updater.menuAction {
        case .showProgress:
            Button {
                presentUpdateWindow(reason: "View Update Progress")
            } label: {
                Label(updater.statusText, systemImage: "arrow.down.circle")
            }
        case .install(let version):
            Button {
                presentUpdateWindow(reason: "Install Available Update")
                updater.installAvailableUpdate()
            } label: {
                Label {
                    Text("Update to VoiceInk \(version)")
                } icon: {
                    Image(systemName: "arrow.down.circle.fill")
                }
            }
        case .check:
            Button {
                presentUpdateWindow(reason: "Check for Updates")
                Task { _ = await updater.checkForUpdates() }
            } label: {
                Label("Check for Updates…", systemImage: "arrow.clockwise")
            }
        }
    }

    private func presentUpdateWindow(reason: String) {
        logger.notice("🧭 Menu bar requested software update window. reason=\(reason, privacy: .public)")
        menuBarManager.activateForPresentedWindow(reason: reason)
        openWindow(id: AppWindowID.softwareUpdate)
    }

    private func showMainWindow(reason: String) {
        let existingWindow = WindowManager.shared.currentMainWindow()
        logger.notice(
            "🧭 Menu bar requested main window. reason=\(reason, privacy: .public); menuBarOnly=\(self.menuBarManager.isMenuBarOnly, privacy: .public); hasExistingMainWindow=\((existingWindow != nil), privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
        )
        menuBarManager.activateForPresentedWindow(reason: reason)

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
            logger.notice(
                "🧭 Menu bar requested SwiftUI to create/open main window. reason=\(reason, privacy: .public); path=createViaOpenWindow"
            )
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
            logger.notice(
                "🧭 Menu bar requested SwiftUI to open existing main window and asked WindowManager to present it. reason=\(reason, privacy: .public); path=existingWindow"
            )
        }
    }

    private func showMainWindowAndNavigate(to destination: String, reason: String) {
        logger.notice(
            "🧭 Menu bar navigation requested. reason=\(reason, privacy: .public); destination=\(destination, privacy: .public); selectedBefore=\(self.mainWindowNavigation.selectedView.rawValue, privacy: .public)"
        )
        mainWindowNavigation.navigate(to: destination)
        logger.notice(
            "🧭 Menu bar navigation state updated. reason=\(reason, privacy: .public); destination=\(destination, privacy: .public); selectedAfter=\(self.mainWindowNavigation.selectedView.rawValue, privacy: .public)"
        )
        showMainWindow(reason: reason)
    }
}

struct UpdateWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var updater = UpdateManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusColor)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle)
                        .font(.title2.weight(.semibold))

                    statusContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    dismissWindow(id: AppWindowID.softwareUpdate)
                }

                actionButton
            }
        }
        .padding(24)
        .frame(width: 420)
        .accessibilityIdentifier("software-update.window")
    }

    private var statusTitle: String {
        switch updater.activity {
        case .failed:
            return String(localized: "Update Failed")
        case .checking:
            return String(localized: "Checking for Updates…")
        case .downloading, .verifying, .preparing, .installing:
            return updater.statusText
        case .idle:
            if let release = updater.availableRelease {
                return String(format: String(localized: "Update to VoiceInk %@"), release.version)
            }
            return updater.lastCheckMessage ?? String(localized: "Software Update")
        }
    }

    private var statusSymbol: String {
        switch updater.activity {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle where updater.availableRelease == nil && updater.lastCheckMessage != nil:
            return "checkmark.circle.fill"
        default:
            return "arrow.down.circle.fill"
        }
    }

    private var statusColor: Color {
        if case .failed = updater.activity { return .red }
        if updater.activity == .idle, updater.availableRelease == nil, updater.lastCheckMessage != nil {
            return .green
        }
        return .blue
    }

    @ViewBuilder
    private var statusContent: some View {
        switch updater.activity {
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                if let percentage = updater.progressPercentage {
                    Text("\(percentage)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let progress = updater.progressFraction {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
        case .checking, .verifying, .preparing, .installing:
            ProgressView()
                .controlSize(.small)
        case .idle:
            if let release = updater.availableRelease {
                Text("VoiceInk \(release.version) is available.")
                    .foregroundStyle(.secondary)
            } else {
                Text(updater.lastCheckMessage ?? String(localized: "Check for Updates"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .failed = updater.activity {
            Button("Retry") {
                retryUpdateOperation()
            }
            .keyboardShortcut(.defaultAction)
        } else if updater.isBusy {
            EmptyView()
        } else if let release = updater.availableRelease {
            Button("Update to VoiceInk \(release.version)") {
                updater.installAvailableUpdate()
            }
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Check for Updates") {
                Task { _ = await updater.checkForUpdates() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func retryUpdateOperation() {
        if updater.availableRelease != nil {
            updater.installAvailableUpdate()
        } else {
            Task { _ = await updater.checkForUpdates() }
        }
    }
}
