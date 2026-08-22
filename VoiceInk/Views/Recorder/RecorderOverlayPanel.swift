import AppKit
import CoreGraphics

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
/// AppKit can temporarily report an ordered panel as not visible while Spaces
/// are transitioning, so presentation state is tracked independently from
/// `isVisible` and the overlay is explicitly reasserted after each transition.
class RecorderOverlayPanel: NSPanel {
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

    private(set) var isRecorderPresented = false
    private var presentationGeneration: UInt = 0
    private var systemSuppressionReasons: Set<RecorderOverlaySystemSuppressionReason> = []
    private var needsFramePreparation = false

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

        // A panel first ordered while another app's full-screen Space is
        // settling can initially be attached to the previous Space. Reassert
        // after the same settling intervals used for an explicit Space change.
        scheduleReassertions(for: presentationGeneration)
    }

    func dismissRecorderOverlay() {
        presentationGeneration &+= 1
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

    private func scheduleReassertions(for generation: UInt) {
        for delay in [0.1, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                    self.isRecorderPresented,
                    self.presentationGeneration == generation
                else {
                    return
                }
                self.reassertRecorderOverlay()
            }
        }
    }

    @objc private func handleActiveSpaceChange() {
        guard isRecorderPresented else { return }

        // Reorder once immediately after the Space changes and once after the
        // full-screen transition settles. The second pass closes the race in
        // which the destination app finishes ordering its full-screen window
        // after AppKit posts the active-Space notification.
        reassertRecorderOverlay(after: 0.1)
        reassertRecorderOverlay(after: 0.4)
    }

    @objc private func handleApplicationActivation() {
        reassertRecorderOverlay()
    }

    @objc private func handleOverlayWindowDidMove() {
        // Interactive movement is handed off to WindowServer. Reapply only
        // the overlay invariants afterwards so a manually chosen position is
        // never replaced by automatic recorder geometry.
        reassertRecorderOverlay()
    }

    @objc private func handleWindowOcclusionChange() {
        guard isRecorderPresented, !occlusionState.contains(.visible) else { return }
        reassertRecorderOverlay()
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
        guard isRecorderPresented else { return }
        orderOut(nil)
    }

    private func resumeRecorderOverlay(afterClearing reason: RecorderOverlaySystemSuppressionReason) {
        systemSuppressionReasons.remove(reason)
        guard isRecorderPresented, systemSuppressionReasons.isEmpty else { return }
        presentationGeneration &+= 1
        restoreRecorderOverlayPolicyAndOrdering(prepareFrame: needsFramePreparation)
        scheduleReassertions(for: presentationGeneration)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
