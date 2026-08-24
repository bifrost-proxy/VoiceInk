import AppKit
import Foundation
import SwiftUI
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini
    case follow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        case .follow:
            return String(localized: "Follow")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            rebuildVisiblePanel(previousStyle: oldValue)
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    var isRecordingPermissionGuidancePresented: Bool {
        isRecorderPanelVisible && engine?.recordingPermissionGuidance != nil
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?
    private var followWindowManager: FollowWindowManager?
    private var followAnchor: NSPoint?

    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderUIManager")

    init() {}

    /// Call after VoiceInkEngine is created to break the circular init dependency.
    func configure(engine: VoiceInkEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
    }

    // MARK: - Recorder Panel Management

    private func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }

        switch recorderPanelStyle {
        case .notch:
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            notchWindowManager?.show()
        case .mini:
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            miniWindowManager?.show()
        case .follow:
            if followWindowManager == nil {
                followWindowManager = FollowWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            followWindowManager?.show(anchor: followAnchor ?? NSEvent.mouseLocation)
        }
    }

    private func hideRecorderPanel() {
        switch recorderPanelStyle {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        case .follow:
            followWindowManager?.hide()
        }
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        switch previousStyle {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        case .follow:
            followWindowManager?.destroyWindow()
            followWindowManager = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        switch engine.recordingState {
        case .recording:
            await engine.toggleRecord(modeId: modeId)
        case .enhancing:
            await cancelEnhancementAndPasteOriginal()
        case .starting, .transcribing:
            await cancelRecording()
        case .idle:
            if isRecorderPanelVisible {
                if let permissionGuidance = engine.recordingPermissionGuidance {
                    switch permissionGuidance {
                    case .required:
                        await engine.beginRecordingPermissionRecovery(modeId: modeId)
                    case .requesting:
                        break
                    case .ready:
                        engine.clearRecordingPermissionGuidance()
                        await startRecording(engine: engine, modeId: modeId)
                    }
                } else if engine.assistantSession.canSendFollowUp {
                    await startRecording(engine: engine, modeId: modeId, isAssistantFollowUp: true)
                } else {
                    await dismissRecorderPanel()
                }
            } else {
                await startRecording(engine: engine, modeId: modeId)
                if engine.recordingPermissionGuidance != nil && !isRecorderPanelVisible {
                    isRecorderPanelVisible = true
                }
            }
        case .busy:
            await dismissRecorderPanel()
        }
    }

    private func startRecording(
        engine: VoiceInkEngine,
        modeId: UUID?,
        isAssistantFollowUp: Bool = false
    ) async {
        if recorderPanelStyle == .follow {
            followAnchor = NSEvent.mouseLocation
        } else {
            followAnchor = nil
        }
        // Preserve the existing pre-capture cue placement. Playback itself is
        // dispatched asynchronously and does not wait on panel construction.
        SoundManager.shared.playStartSound()
        await engine.toggleRecord(
            modeId: modeId,
            isAssistantFollowUp: isAssistantFollowUp
        ) { [weak self] in
            self?.isRecorderPanelVisible = true
        }
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.clearRecordingPermissionGuidance()
        engine.assistantSession.reset()
        followAnchor = nil
    }

    func presentRecordingPermissionGuidance(modeId: UUID? = nil) async {
        guard let engine else { return }
        guard OnboardingRuntimeGate.allowsRecordingRuntime(
            hasCompletedOnboarding: UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2")
        ) else { return }

        engine.prepareRecordingPermissionRecovery(modeId: modeId)
        isRecorderPanelVisible = true
    }

    func refreshRecordingPermissionGuidance() {
        engine?.refreshRecordingPermissionGuidance()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.clearRecordingPermissionGuidance()
        engine.assistantSession.reset()
        followAnchor = nil
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    func cancelEnhancementAndPasteOriginal() async {
        guard let engine = engine else { return }
        await engine.cancelEnhancementAndPasteOriginal()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
