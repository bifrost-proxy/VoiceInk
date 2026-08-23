import AppKit
import CoreGraphics
import OSLog

enum RecorderOverlaySystemSuppressionReason: Hashable {
    case inactiveSession
    case screenSaver
    case screenSleep
    case screenLock
}

/// Process-lifetime snapshot of system states in which recorder content must
/// not be shown. It starts during application initialization, before recorder
/// panels are created lazily, so a new panel cannot miss an earlier transition.
@MainActor
final class RecorderOverlaySystemStateMonitor: NSObject {
    static let shared = RecorderOverlaySystemStateMonitor()

    private(set) var suppressionReasons: Set<RecorderOverlaySystemSuppressionReason> = []

    static let screenSaverDidStartNotification = Notification.Name(
        "com.apple.screensaver.didstart"
    )
    static let screenSaverDidStopNotification = Notification.Name(
        "com.apple.screensaver.didstop"
    )
    static let screenDidLockNotification = Notification.Name(
        "com.apple.screenIsLocked"
    )
    static let screenDidUnlockNotification = Notification.Name(
        "com.apple.screenIsUnlocked"
    )

    private override init() {
        super.init()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(handleScreenSaverDidStart),
            name: Self.screenSaverDidStartNotification,
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(handleScreenSaverDidStop),
            name: Self.screenSaverDidStopNotification,
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(handleScreenDidLock),
            name: Self.screenDidLockNotification,
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(handleScreenDidUnlock),
            name: Self.screenDidUnlockNotification,
            object: nil
        )
    }

    @objc private func handleSessionDidResignActive() {
        suppressionReasons.insert(.inactiveSession)
    }

    @objc private func handleSessionDidBecomeActive() {
        suppressionReasons.remove(.inactiveSession)
    }

    @objc private func handleScreensDidSleep() {
        suppressionReasons.insert(.screenSleep)
    }

    @objc private func handleScreensDidWake() {
        suppressionReasons.remove(.screenSleep)
    }

    @objc private func handleScreenSaverDidStart() {
        suppressionReasons.insert(.screenSaver)
    }

    @objc private func handleScreenSaverDidStop() {
        suppressionReasons.remove(.screenSaver)
    }

    @objc private func handleScreenDidLock() {
        suppressionReasons.insert(.screenLock)
    }

    @objc private func handleScreenDidUnlock() {
        suppressionReasons.remove(.screenLock)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

/// Shared window policy for every recorder presentation.
///
/// Recorder panels are system-style overlays: they must remain available in
/// every Space, including full-screen Spaces owned by another application.
/// AppKit's `isVisible` only reflects local ordering state; WindowServer can
/// still leave an ordered panel detached from the current full-screen Space.
/// Presentation state is therefore tracked independently and server-side
/// visibility is verified after every transition.
class RecorderOverlayPanel: NSPanel {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "RecorderOverlay"
    )
    // Some full-screen players and presentation apps use the screen-saver
    // level themselves. A recorder at the same level then depends on which
    // application orders its window last. The public assistive-technology
    // level gives this accessibility overlay a deterministic level above
    // those windows while remaining below WindowServer's secure shielding.
    static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow))
    )
    static let overlayCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]
    static let activeSpaceRecoveryCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    private(set) var isRecorderPresented = false
    private var presentationGeneration: UInt = 0
    private var visibilityRecoveryGeneration: UInt = 0
    private var isVisibilityRecoveryActive = false
    private var systemSuppressionReasons: Set<RecorderOverlaySystemSuppressionReason> = []
    private var needsFramePreparation = false
    private var isReattachingToActiveSpace = false

    // The checks span the normal full-screen animation and a short settling
    // period. They stop as soon as WindowServer reports the panel on screen.
    // Internal overrides keep the state machine deterministic in unit tests.
    var visibilityRecoveryIntervals: [TimeInterval] { [0.15, 0.25, 0.35, 0.45] }
    var recorderOverlayOnScreenProvider: ((CGWindowID) -> Bool)?
    var activeSpaceReattachmentHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        isFloatingPanel = true
        canHide = false
        level = Self.overlayLevel
        hidesOnDeactivate = false
        collectionBehavior = Self.overlayCollectionBehavior

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationActivation),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenSaverDidStart),
            name: RecorderOverlaySystemStateMonitor.screenSaverDidStartNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenSaverDidStop),
            name: RecorderOverlaySystemStateMonitor.screenSaverDidStopNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenDidLock),
            name: RecorderOverlaySystemStateMonitor.screenDidLockNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenDidUnlock),
            name: RecorderOverlaySystemStateMonitor.screenDidUnlockNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOverlayWindowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowOcclusionChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )
    }

    func presentRecorderOverlay() {
        presentationGeneration &+= 1
        isRecorderPresented = true
        systemSuppressionReasons = RecorderOverlaySystemStateMonitor.shared.suppressionReasons
        needsFramePreparation = false
        if systemSuppressionReasons.isEmpty {
            restoreRecorderOverlayPolicyAndOrdering(prepareFrame: true)
        } else {
            prepareRecorderOverlayForPresentation()
            orderOut(nil)
        }

        beginVisibilityRecovery()
    }

    func dismissRecorderOverlay() {
        presentationGeneration &+= 1
        visibilityRecoveryGeneration &+= 1
        isVisibilityRecoveryActive = false
        isRecorderPresented = false
        needsFramePreparation = false
        orderOut(nil)
    }

    /// Subclasses update their screen-dependent frame for initial presentation
    /// or after display geometry changes. Ordering repairs deliberately skip
    /// this step so a user-selected position remains stable.
    func prepareRecorderOverlayForPresentation() {}

    func reassertRecorderOverlay() {
        guard isRecorderPresented, systemSuppressionReasons.isEmpty else { return }
        restoreRecorderOverlayPolicyAndOrdering(prepareFrame: false)
    }

    private func restoreRecorderOverlayPolicyAndOrdering(prepareFrame: Bool) {
        // Setting `isFloatingPanel` changes the level back to `.floating`, so
        // apply that flag before restoring the recorder's stronger level.
        isFloatingPanel = true
        canHide = false
        hidesOnDeactivate = false
        level = Self.overlayLevel
        collectionBehavior = Self.overlayCollectionBehavior
        if prepareFrame {
            prepareRecorderOverlayForPresentation()
            needsFramePreparation = false
        }
        orderFrontRegardless()
    }

    func reassertRecorderOverlay(after delay: TimeInterval, prepareFrame: Bool = false) {
        guard isRecorderPresented else { return }
        if prepareFrame {
            needsFramePreparation = true
        }
        guard systemSuppressionReasons.isEmpty else { return }
        let generation = presentationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRecorderPresented, self.presentationGeneration == generation else {
                return
            }
            guard self.systemSuppressionReasons.isEmpty else {
                if prepareFrame {
                    self.needsFramePreparation = true
                }
                return
            }
            self.restoreRecorderOverlayPolicyAndOrdering(
                prepareFrame: prepareFrame || self.needsFramePreparation
            )
        }
    }

    func isRecorderOverlayOnScreen() -> Bool {
        guard isVisible else { return false }
        let windowID = CGWindowID(windowNumber)
        if let recorderOverlayOnScreenProvider {
            return recorderOverlayOnScreenProvider(windowID)
        }

        guard windowID != kCGNullWindowID,
            let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]],
            let recorderInfo = windowInfo.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
            })
        else {
            return false
        }

        return (recorderInfo[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
    }

    private func beginVisibilityRecovery(restart: Bool = false) {
        guard isRecorderPresented, systemSuppressionReasons.isEmpty else { return }
        restoreRecorderOverlayPolicyAndOrdering(prepareFrame: false)
        guard restart || !isVisibilityRecoveryActive else { return }
        isVisibilityRecoveryActive = true
        visibilityRecoveryGeneration &+= 1
        let recoveryGeneration = visibilityRecoveryGeneration
        let presentationGeneration = presentationGeneration

        runVisibilityRecoveryCheck(
            at: 0,
            recoveryGeneration: recoveryGeneration,
            presentationGeneration: presentationGeneration
        )
    }

    private func runVisibilityRecoveryCheck(
        at index: Int,
        recoveryGeneration: UInt,
        presentationGeneration: UInt
    ) {
        guard index < visibilityRecoveryIntervals.count else {
            if visibilityRecoveryGeneration == recoveryGeneration,
                self.presentationGeneration == presentationGeneration
            {
                isVisibilityRecoveryActive = false
            }
            return
        }
        let delay = visibilityRecoveryIntervals[index]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                self.isRecorderPresented,
                self.systemSuppressionReasons.isEmpty,
                self.visibilityRecoveryGeneration == recoveryGeneration,
                self.presentationGeneration == presentationGeneration
            else {
                return
            }

            guard !self.isRecorderOverlayOnScreen() else {
                self.isVisibilityRecoveryActive = false
                return
            }

            if index == 0 {
                // During the animation, a normal reassertion is enough in the
                // common case and avoids unnecessary server-side reattachment.
                self.restoreRecorderOverlayPolicyAndOrdering(prepareFrame: false)
            } else {
                self.reattachRecorderOverlayToActiveSpace(
                    recoveryGeneration: recoveryGeneration,
                    presentationGeneration: presentationGeneration
                )
            }

            self.runVisibilityRecoveryCheck(
                at: index + 1,
                recoveryGeneration: recoveryGeneration,
                presentationGeneration: presentationGeneration
            )
        }
    }

    private func reattachRecorderOverlayToActiveSpace(
        recoveryGeneration: UInt,
        presentationGeneration: UInt
    ) {
        if let activeSpaceReattachmentHandler {
            activeSpaceReattachmentHandler()
            return
        }

        Self.logger.notice(
            "Recorder window \(self.windowNumber, privacy: .public) remains off screen; reattaching to the active Space"
        )

        // Preserve both SwiftUI content and the user-selected frame. Ordering
        // out and briefly using moveToActiveSpace gives WindowServer an
        // explicit opportunity to attach this same panel to the destination
        // Space; the all-Spaces policy is restored on the next run-loop turn.
        let preservedFrame = frame
        isReattachingToActiveSpace = true
        orderOut(nil)

        DispatchQueue.main.async { [weak self] in
            guard let self,
                self.isRecorderPresented,
                self.systemSuppressionReasons.isEmpty,
                self.visibilityRecoveryGeneration == recoveryGeneration,
                self.presentationGeneration == presentationGeneration
            else {
                self?.isReattachingToActiveSpace = false
                return
            }
            self.collectionBehavior = Self.activeSpaceRecoveryCollectionBehavior
            self.setFrame(preservedFrame, display: false)
            self.orderFrontRegardless()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isRecorderPresented,
                    self.systemSuppressionReasons.isEmpty,
                    self.visibilityRecoveryGeneration == recoveryGeneration,
                    self.presentationGeneration == presentationGeneration
                else {
                    self.isReattachingToActiveSpace = false
                    return
                }
                self.restoreRecorderOverlayPolicyAndOrdering(prepareFrame: false)
                self.isReattachingToActiveSpace = false
            }
        }
    }

    @objc private func handleActiveSpaceChange() {
        guard isRecorderPresented else { return }
        beginVisibilityRecovery(restart: true)
    }

    @objc private func handleApplicationActivation() {
        beginVisibilityRecovery()
    }

    @objc private func handleOverlayWindowDidMove() {
        // Interactive movement is handed off to WindowServer. Reapply only
        // the overlay invariants afterwards so a manually chosen position is
        // never replaced by automatic recorder geometry.
        guard !isReattachingToActiveSpace else { return }
        reassertRecorderOverlay()
    }

    @objc private func handleWindowOcclusionChange() {
        guard isRecorderPresented,
            !isReattachingToActiveSpace,
            !occlusionState.contains(.visible)
        else {
            return
        }
        beginVisibilityRecovery()
    }

    @objc private func handleSessionDidResignActive() {
        suppressRecorderOverlay(for: .inactiveSession)
    }

    @objc private func handleSessionDidBecomeActive() {
        resumeRecorderOverlay(afterClearing: .inactiveSession)
    }

    @objc private func handleScreensDidSleep() {
        suppressRecorderOverlay(for: .screenSleep)
    }

    @objc private func handleScreensDidWake() {
        resumeRecorderOverlay(afterClearing: .screenSleep)
    }

    @objc private func handleScreenSaverDidStart() {
        suppressRecorderOverlay(for: .screenSaver)
    }

    @objc private func handleScreenSaverDidStop() {
        resumeRecorderOverlay(afterClearing: .screenSaver)
    }

    @objc private func handleScreenDidLock() {
        suppressRecorderOverlay(for: .screenLock)
    }

    @objc private func handleScreenDidUnlock() {
        resumeRecorderOverlay(afterClearing: .screenLock)
    }

    private func suppressRecorderOverlay(for reason: RecorderOverlaySystemSuppressionReason) {
        systemSuppressionReasons.insert(reason)
        presentationGeneration &+= 1
        visibilityRecoveryGeneration &+= 1
        isVisibilityRecoveryActive = false
        guard isRecorderPresented else { return }
        orderOut(nil)
    }

    private func resumeRecorderOverlay(afterClearing reason: RecorderOverlaySystemSuppressionReason) {
        systemSuppressionReasons.remove(reason)
        guard isRecorderPresented, systemSuppressionReasons.isEmpty else { return }
        presentationGeneration &+= 1
        restoreRecorderOverlayPolicyAndOrdering(prepareFrame: needsFramePreparation)
        beginVisibilityRecovery()
    }

    override func close() {
        if isRecorderPresented {
            dismissRecorderOverlay()
        }
        super.close()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
