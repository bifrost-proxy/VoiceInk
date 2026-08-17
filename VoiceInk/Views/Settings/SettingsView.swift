import Carbon.HIToolbox
import Cocoa
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @ObservedObject private var cloudSync = CloudConfigurationSyncService.shared
    @ObservedObject private var usageSync = CloudUsageDataSyncService.shared
    @ObservedObject private var updater = UpdateManager.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(CloudSyncSettingsKeys.configurationSyncEnabled) private var configurationSyncEnabled = true
    @AppStorage(CloudSyncSettingsKeys.usageDataSyncEnabled) private var usageDataSyncEnabled = false
    @AppStorage(CloudSyncSettingsKeys.usageAudioSyncEnabled) private var usageAudioSyncEnabled = false
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false
    @State private var hasCancelRecordingShortcut = ShortcutStore.shortcut(for: .cancelRecorder) != nil
    @State private var cancelRecordingShortcutRecorderResetID = 0

    @State private var isMiddleClickExpanded = false
    @State private var isRestoreClipboardExpanded = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Primary Shortcut") {
                    HStack(spacing: 8) {
                        Spacer()
                        shortcutModePicker(binding: $recordingShortcutManager.primaryRecordingShortcutMode)
                        ShortcutRecorder(action: .primaryRecording) {
                            recordingShortcutManager.primaryRecordingShortcut = .custom
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut != .none {
                    LabeledContent("Secondary Shortcut") {
                        HStack(spacing: 8) {
                            Spacer()
                            shortcutModePicker(binding: $recordingShortcutManager.secondaryRecordingShortcutMode)
                            ShortcutRecorder(action: .secondaryRecording) {
                                recordingShortcutManager.secondaryRecordingShortcut = .custom
                                recordingShortcutManager.updateShortcutStatus()
                            }
                            .controlSize(.small)
                            Button {
                                withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .none }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut == .none {
                    Button("Add Second Shortcut") {
                        withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .custom }
                    }
                }
            } header: {
                Text("Shortcuts")
            }

            Section("Additional Shortcuts") {
                LabeledContent("Paste Last Transcription (Original)") {
                    ShortcutRecorder(action: .pasteLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Paste Last Transcription (Enhanced)") {
                    ShortcutRecorder(action: .pasteLastEnhancement) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Retry Last Transcription") {
                    ShortcutRecorder(action: .retryLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Cancel Recording") {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            action: .cancelRecorder,
                            defaultShortcut: Self.defaultCancelRecordingShortcut
                        ) {
                            hasCancelRecordingShortcut = true
                        }
                        .id(cancelRecordingShortcutRecorderResetID)
                        .controlSize(.small)

                        Button {
                            ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                            hasCancelRecordingShortcut = false
                            cancelRecordingShortcutRecorderResetID += 1
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
                    guard let action = notification.object as? ShortcutAction, action == .cancelRecorder else { return }
                    hasCancelRecordingShortcut = ShortcutStore.shortcut(for: .cancelRecorder) != nil
                }

                ExpandableSettingsRow(
                    isExpanded: $isMiddleClickExpanded,
                    isEnabled: $recordingShortcutManager.isMiddleClickToggleEnabled,
                    label: "Middle-Click Recording"
                ) {
                    LabeledContent("Activation Delay") {
                        HStack {
                            TextField(
                                "", value: $recordingShortcutManager.middleClickActivationDelay,
                                formatter: {
                                    let formatter = NumberFormatter()
                                    formatter.minimum = 0
                                    return formatter
                                }()
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            Text("ms")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("Pasting") {
                ExpandableSettingsRow(
                    isExpanded: $isRestoreClipboardExpanded,
                    isEnabled: $restoreClipboardAfterPaste,
                    label: "Keep Clipboard Content",
                    infoMessage:
                        "VoiceInk temporarily uses the clipboard to paste transcription. When enabled, it restores your previous clipboard content after the selected delay. When disabled, the pasted transcription stays on your clipboard."
                ) {
                    Picker("Restore Delay", selection: $clipboardRestoreDelay) {
                        Text("250ms").tag(0.25)
                        Text("500ms").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("4s").tag(4.0)
                        Text("5s").tag(5.0)
                    }
                }

                Picker(selection: $pasteMethodRawValue) {
                    ForEach(PasteMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Paste Method")
                        InfoTip(
                            "Default uses simulated Cmd+V key events. AppleScript can help when custom keyboard layouts do not paste correctly."
                        )
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pasteMethodRawValue) { _, newValue in
                    guard let method = PasteMethod(rawValue: newValue) else {
                        pasteMethodRawValue = PasteMethod.standard.rawValue
                        return
                    }
                    PasteMethod.setCurrent(method)
                }
            }

            Section("Interface") {
                Picker("Appearance", selection: $appAppearancePreference) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appAppearancePreference) { _, newValue in
                    newValue.apply()
                }

                Picker("Language", selection: $appLanguagePreference) {
                    ForEach(AppLanguagePreference.availableOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appLanguagePreference) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                    if normalizedValue != newValue {
                        appLanguagePreference = normalizedValue
                        return
                    }
                    AppLanguagePreference.apply(rawValue: normalizedValue)
                    showLanguageRestartAlert = true
                }

                Picker("Recorder Style", selection: $recorderUIManager.recorderPanelStyle) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: $showLiveTranscript) {
                    HStack(spacing: 4) {
                        Text("Live Text Display")
                        InfoTip("Shows live text while recording with realtime models.")
                    }
                }
            }

            Section("General") {
                Toggle("Hide Dock Icon", isOn: $menuBarManager.isMenuBarOnly)

                LaunchAtLogin.Toggle(String(localized: "Launch at Login"))

                Button("Reset Onboarding") {
                    showResetOnboardingAlert = true
                }
            }

            Section {
                Toggle("Sync Configuration", isOn: $configurationSyncEnabled)
                    .onChange(of: configurationSyncEnabled) { _, enabled in
                        cloudSync.setEnabled(enabled)
                    }

                LabeledContent("iCloud Sync") {
                    HStack(spacing: 8) {
                        if cloudSync.state == .syncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(cloudSync.statusText)
                            .foregroundStyle(cloudSync.errorText == nil ? Color.secondary : Color.red)
                    }
                }

                if let lastSyncedAt = cloudSync.lastSyncedAt {
                    LabeledContent("Last Synced") {
                        Text(lastSyncedAt, format: .dateTime.year().month().day().hour().minute().second())
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText = cloudSync.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Sync Now") {
                        cloudSync.syncNow()
                    }
                    .disabled(!configurationSyncEnabled)
                    Button("Show Sync File") {
                        cloudSync.revealConfigurationFile()
                    }
                    .disabled(cloudSync.configurationFileURL == nil)
                }

                Divider()

                Toggle("Sync Usage Data", isOn: $usageDataSyncEnabled)
                    .onChange(of: usageDataSyncEnabled) { _, enabled in
                        usageSync.setEnabled(enabled)
                    }

                if usageDataSyncEnabled {
                    LabeledContent("This Device") {
                        Text(usageSync.localDeviceName)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Include Source Audio", isOn: $usageAudioSyncEnabled)
                        .onChange(of: usageAudioSyncEnabled) { _, enabled in
                            usageSync.setAudioEnabled(enabled)
                        }

                    LabeledContent("Usage Data") {
                        HStack(spacing: 8) {
                            if usageSync.state == .syncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(usageSync.statusText)
                                .foregroundStyle(usageSync.errorText == nil ? Color.secondary : Color.red)
                        }
                    }

                    LabeledContent("Synchronized Records") {
                        Text(usageSync.synchronizedRecordCount, format: .number)
                            .foregroundStyle(.secondary)
                    }

                    if let lastSyncedAt = usageSync.lastSyncedAt {
                        LabeledContent("Usage Last Synced") {
                            Text(lastSyncedAt, format: .dateTime.year().month().day().hour().minute().second())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorText = usageSync.errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Sync Usage Now") {
                            usageSync.syncNow()
                        }
                        Button("Show Usage Data") {
                            usageSync.revealUsageData()
                        }
                        .disabled(usageSync.usageDataDirectoryURL == nil)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(
                    "Configuration sync is on by default. Usage data sync is opt-in and includes transcription history, corrections, reports, and every persisted transcription-stage performance measurement. Source audio requires a separate opt-in. API keys, permissions, device selections, and downloaded model files always stay on this Mac."
                )
            }

            Section {
                LabeledContent("Export Settings") {
                    Button("Export") {
                        ImportExportService.shared.exportSettings(
                            enhancementService: enhancementService,
                            recordingShortcutManager: recordingShortcutManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext
                        )
                    }
                }

                LabeledContent("Import Settings") {
                    Button("Import") {
                        ImportExportService.shared.importSettings(
                            enhancementService: enhancementService,
                            recordingShortcutManager: recordingShortcutManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext,
                            transcriptionModelManager: transcriptionModelManager
                        )
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export all settings, or choose specific categories when importing a backup.")
            }

            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }

            Section {
                LabeledContent("Installed Version") {
                    Text("Version \(Self.appVersion) (\(Self.appBuild))")
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Auto-check Updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )
                )

                if updater.isBusy {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(updater.statusText)
                            Spacer()
                            if let percentage = updater.progressPercentage {
                                Text("\(percentage)%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let progress = updater.progressFraction {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } else if let release = updater.availableRelease {
                    LabeledContent {
                        Button {
                            updater.installAvailableUpdate()
                        } label: {
                            Text("Update to VoiceInk \(release.version)")
                        }
                    } label: {
                        Text("VoiceInk \(release.version) is available.")
                    }
                } else {
                    HStack {
                        Button("Check for Updates") {
                            Task { _ = await updater.checkForUpdates() }
                        }
                        Spacer()
                        if let message = updater.lastCheckMessage {
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }

                }

                if case .failed(let message) = updater.activity {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(
                    "When enabled, VoiceInk checks for a new version at launch and once every hour. Downloaded updates are verified before VoiceInk installs and restarts automatically."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            cloudSync.syncNow()
        }
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart VoiceInk to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen VoiceInk.")
        }
    }

    private static let defaultCancelRecordingShortcut = Shortcut.key(
        keyCode: UInt16(kVK_Escape),
        modifierFlags: []
    )

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    @ViewBuilder
    private func shortcutModePicker(binding: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("", selection: binding) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

extension Text {
    func settingsDescription() -> some View {
        self
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
