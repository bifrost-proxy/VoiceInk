import AppKit
import Foundation
import OSLog

/// Polls only while Accessibility recovery is needed. Two successful rebuilds
/// avoid treating the first TCC transition callback as a fully settled event tap.
@MainActor
final class AccessibilityAuthorizationMonitor {
    private let pollingIntervalNanoseconds: UInt64
    private let maximumRetryIntervalNanoseconds: UInt64
    private let requiredConsecutiveSuccesses: Int
    private let isAuthorized: @MainActor () -> Bool
    private let onRecoveryAttempt: @MainActor () -> Bool
    private var pollingTask: Task<Void, Never>?

    init(
        pollingIntervalNanoseconds: UInt64 = 500_000_000,
        maximumRetryIntervalNanoseconds: UInt64 = 30_000_000_000,
        requiredConsecutiveSuccesses: Int = 2,
        isAuthorized: @escaping @MainActor () -> Bool,
        onRecoveryAttempt: @escaping @MainActor () -> Bool
    ) {
        self.pollingIntervalNanoseconds = pollingIntervalNanoseconds
        self.maximumRetryIntervalNanoseconds = max(
            pollingIntervalNanoseconds,
            maximumRetryIntervalNanoseconds
        )
        self.requiredConsecutiveSuccesses = max(1, requiredConsecutiveSuccesses)
        self.isAuthorized = isAuthorized
        self.onRecoveryAttempt = onRecoveryAttempt
    }

    func start() {
        guard pollingTask == nil else { return }

        let pollingIntervalNanoseconds = pollingIntervalNanoseconds
        let maximumRetryIntervalNanoseconds = maximumRetryIntervalNanoseconds
        let requiredConsecutiveSuccesses = requiredConsecutiveSuccesses
        pollingTask = Task { @MainActor [weak self] in
            var consecutiveSuccesses = 0
            var retryIntervalNanoseconds = pollingIntervalNanoseconds

            while !Task.isCancelled {
                guard let self else { return }

                if self.isAuthorized() {
                    if self.onRecoveryAttempt() {
                        consecutiveSuccesses += 1
                        retryIntervalNanoseconds = pollingIntervalNanoseconds
                        if consecutiveSuccesses >= requiredConsecutiveSuccesses {
                            self.pollingTask = nil
                            return
                        }
                    } else {
                        consecutiveSuccesses = 0
                        retryIntervalNanoseconds = min(
                            maximumRetryIntervalNanoseconds,
                            retryIntervalNanoseconds > maximumRetryIntervalNanoseconds / 2
                                ? maximumRetryIntervalNanoseconds
                                : retryIntervalNanoseconds * 2
                        )
                    }
                } else {
                    consecutiveSuccesses = 0
                    retryIntervalNanoseconds = pollingIntervalNanoseconds
                }

                do {
                    try await Task.sleep(nanoseconds: retryIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    deinit {
        pollingTask?.cancel()
    }

    var isRunning: Bool {
        pollingTask != nil
    }
}

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }

    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private let menuBarManager: MenuBarManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ShortcutMonitor")
    private lazy var accessibilityFallbackMonitor = AccessibilityShortcutFallbackMonitor { [weak self] in
        Task { @MainActor [weak self] in
            await self?.recorderUIManager.presentRecordingPermissionGuidance()
        }
    }
    private lazy var accessibilityAuthorizationMonitor = AccessibilityAuthorizationMonitor(
        isAuthorized: { AXIsProcessTrusted() },
        onRecoveryAttempt: { [weak self] in
            guard let self else { return true }
            let succeeded = self.refreshShortcutMonitoringAfterAccessibilityAuthorization()
            self.logger.notice(
                "Accessibility shortcut recovery attempt completed. succeeded=\(succeeded, privacy: .public)"
            )
            return succeeded
        }
    )
    private var shortcutChangeObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource
    private var preservesShortcutPressStateDuringRecovery = false

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }

    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    enum MissingAccessibilityPresentation: Equatable {
        case suppressed
        case recorderGuidance
        case standalonePrompt
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(
        engine: VoiceInkEngine,
        recorderUIManager: RecorderUIManager,
        menuBarManager: MenuBarManager
    ) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            cancelEnhancementAndPasteOriginal: {
                await recorderUIManager.cancelEnhancementAndPasteOriginal()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.menuBarManager = menuBarManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recorderUIManager.refreshRecordingPermissionGuidance()
                guard AXIsProcessTrusted() else {
                    self?.refreshShortcutMonitoring()
                    return
                }
                self?.refreshShortcutMonitoringAfterAccessibilityAuthorization()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }

    @discardableResult
    private func refreshShortcutMonitoring() -> Bool {
        removeActiveShortcutMonitoring()

        guard OnboardingRuntimeGate.allowsRecordingRuntime(
            hasCompletedOnboarding: UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2")
        ) else {
            accessibilityAuthorizationMonitor.stop()
            return false
        }

        guard AXIsProcessTrusted() else {
            accessibilityAuthorizationMonitor.start()
            let shortcuts = configuredShortcutsForAccessibilityFallback()
            let fallbackCount = accessibilityFallbackMonitor.start(shortcuts: shortcuts)
            switch Self.missingAccessibilityPresentation(
                isRecorderGuidancePresented: recorderUIManager.isRecordingPermissionGuidancePresented,
                recordingShortcuts: configuredRecordingShortcuts(),
                configuredShortcutCount: shortcuts.count,
                registeredFallbackCount: fallbackCount
            ) {
            case .suppressed:
                break
            case .recorderGuidance:
                Task { @MainActor [weak self] in
                    await self?.recorderUIManager.presentRecordingPermissionGuidance()
                }
            case .standalonePrompt:
                AccessibilityShortcutPermissionPrompt.showIfNeeded()
            }
            return false
        }

        let started = refreshShortcutMonitor()
        setupMiddleClickMonitoring()
        if !started {
            accessibilityAuthorizationMonitor.start()
        }
        return started
    }

    @discardableResult
    private func refreshShortcutMonitoringAfterAccessibilityAuthorization() -> Bool {
        let recordingShortcutsStarted = refreshShortcutMonitoring()
        let modeShortcutsStarted = modeShortcutManager.refreshAfterAccessibilityAuthorization()
        let recorderPanelShortcutsStarted = recorderPanelShortcutManager.refreshAfterAccessibilityAuthorization()
        return recordingShortcutsStarted && modeShortcutsStarted && recorderPanelShortcutsStarted
    }

    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000  // ms to ns
                    try await Task.sleep(nanoseconds: delay)

                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }

                    Task { @MainActor in
                        guard self.canHandleShortcutAction else { return }
                        await self.recorderUIManager.toggleRecorderPanel()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }

    private func refreshShortcutMonitor() -> Bool {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        let started = shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )

        if !started {
            AccessibilityShortcutPermissionPrompt.showIfNeeded()
        }
        return started
    }

    private func configuredShortcutsForAccessibilityFallback() -> [Shortcut] {
        var shortcuts = Array(
            ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions).values
        )
        shortcuts.append(contentsOf: configuredRecordingShortcuts())
        return shortcuts
    }

    private func configuredRecordingShortcuts() -> [Shortcut] {
        var shortcuts: [Shortcut] = []
        if primaryRecordingShortcut == .custom,
            let shortcut = ShortcutStore.shortcut(for: .primaryRecording)
        {
            shortcuts.append(shortcut)
        }
        if secondaryRecordingShortcut == .custom,
            let shortcut = ShortcutStore.shortcut(for: .secondaryRecording)
        {
            shortcuts.append(shortcut)
        }
        for config in ModeManager.shared.enabledConfigurations {
            if let shortcut = ShortcutStore.shortcut(for: .mode(config.id)) {
                shortcuts.append(shortcut)
            }
        }
        return shortcuts
    }

    static func needsProactiveAccessibilityGuidance(
        recordingShortcuts: [Shortcut],
        configuredShortcutCount: Int,
        registeredFallbackCount: Int
    ) -> Bool {
        recordingShortcuts.contains(where: \.isModifierOnly)
            || (configuredShortcutCount > 0 && registeredFallbackCount == 0)
    }

    static func missingAccessibilityPresentation(
        isRecorderGuidancePresented: Bool,
        recordingShortcuts: [Shortcut],
        configuredShortcutCount: Int,
        registeredFallbackCount: Int
    ) -> MissingAccessibilityPresentation {
        if isRecorderGuidancePresented {
            return .suppressed
        }
        if needsProactiveAccessibilityGuidance(
            recordingShortcuts: recordingShortcuts,
            configuredShortcutCount: configuredShortcutCount,
            registeredFallbackCount: registeredFallbackCount
        ) {
            return .recorderGuidance
        }
        return .standalonePrompt
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .copyLastTranscription:
            LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openHistoryWindow:
            menuBarManager.openHistoryWindow()
        case .toggleDockIcon:
            menuBarManager.toggleMenuBarOnly()
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeActiveShortcutMonitoring() {
        shortcutMonitor.stop()
        accessibilityFallbackMonitor.stop()

        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()

        if !preservesShortcutPressStateDuringRecovery {
            shortcutModeHandler.reset()
        }
    }

    private func removeAllMonitoring() {
        removeActiveShortcutMonitoring()
        accessibilityAuthorizationMonitor.stop()
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    func refreshAfterLaunchReset() {
        refreshShortcutMonitoring()
    }

    /// Rebuilds every process-local shortcut monitor after macOS resumes the
    /// app or restarts an event-related service. Re-enabling an existing event
    /// tap is not sufficient when its Mach port or run-loop source is stale.
    @discardableResult
    func recoverRuntimeMonitoring() -> Bool {
        // A push-to-talk key may still be held while the monitor is rebuilt.
        // Preserve that press so the replacement monitor can consume key-up
        // and stop the recording normally.
        preservesShortcutPressStateDuringRecovery = true
        defer { preservesShortcutPressStateDuringRecovery = false }
        let succeeded: Bool
        if AXIsProcessTrusted() {
            succeeded = refreshShortcutMonitoringAfterAccessibilityAuthorization()
        } else {
            succeeded = refreshShortcutMonitoring()
        }
        logger.notice(
            "Runtime shortcut monitoring rebuild completed. succeeded=\(succeeded, privacy: .public) accessibilityTrusted=\(AXIsProcessTrusted(), privacy: .public)"
        )
        return succeeded
    }

    func refreshForOnboardingStateChange() {
        refreshShortcutMonitoring()
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void
    private let cancelEnhancementAndPasteOriginal: @MainActor () async -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var isBypassingEnhancementForCurrentShortcut = false
    private var lastShortcutPressTime: Date?

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        cancelEnhancementAndPasteOriginal: @escaping @MainActor () async -> Void
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
        self.cancelEnhancementAndPasteOriginal = cancelEnhancementAndPasteOriginal
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        isBypassingEnhancementForCurrentShortcut = false
    }

    var hasActivePress: Bool {
        isShortcutPressed
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if let lastTrigger = lastShortcutPressTime,
            Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown
        {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
        lastShortcutPressTime = Date()
        shortcutPressStartTime = eventTime

        if recordingState() == .enhancing {
            isBypassingEnhancementForCurrentShortcut = true
            await cancelEnhancementAndPasteOriginal()
            return
        }

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }
        }
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false

        if isBypassingEnhancementForCurrentShortcut {
            isBypassingEnhancementForCurrentShortcut = false
            shortcutPressStartTime = nil
            return
        }

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if recordingState() == .starting || recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold
                && (recordingState() == .starting || recordingState() == .recording)
            {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
