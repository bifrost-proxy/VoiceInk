import AppKit
import CoreGraphics
import Testing
@testable import VoiceInk

@MainActor
@Suite(.serialized)
struct RecorderOverlayPanelTests {
    private final class FramePreparationTrackingPanel: RecorderOverlayPanel {
        var preparationCount = 0

        convenience init() {
            self.init(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                styleMask: [.nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }

        override func prepareRecorderOverlayForPresentation() {
            preparationCount += 1
        }
    }

    private final class VisibilityRecoveryTrackingPanel: RecorderOverlayPanel {
        var testRecoveryIntervals: [TimeInterval] = [0.01, 0.01, 0.01, 0.01]
        override var visibilityRecoveryIntervals: [TimeInterval] { testRecoveryIntervals }

        convenience init() {
            self.init(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                styleMask: [.nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }
    }

    @Test("Every recorder style can join other applications in full screen")
    func recorderPanelsUseCrossApplicationOverlayPolicy() {
        let panels: [RecorderOverlayPanel] = [
            MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)),
            FollowRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 184, height: 40)),
            NotchRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 430)),
        ]
        defer { panels.forEach { $0.close() } }

        #expect(
            RecorderOverlayPanel.overlayLevel.rawValue
                == Int(CGWindowLevelForKey(.assistiveTechHighWindow))
        )
        #expect(RecorderOverlayPanel.overlayLevel > .screenSaver)
        #expect(
            RecorderOverlayPanel.overlayLevel.rawValue
                < Int(CGShieldingWindowLevel())
        )

        for panel in panels {
            #expect(panel.level == RecorderOverlayPanel.overlayLevel)
            #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
            #expect(panel.collectionBehavior.contains(.canJoinAllApplications))
            #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(panel.collectionBehavior.contains(.stationary))
            #expect(panel.collectionBehavior.contains(.ignoresCycle))
            #expect(panel.styleMask.contains(.nonactivatingPanel))
            #expect(!panel.hidesOnDeactivate)
        }
    }

    @Test("WindowServer places the recorder at the assistive overlay layer")
    func usesAssistiveOverlayLayerInWindowServer() async throws {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = contentView
        panel.presentRecorderOverlay()

        // Ordering is committed to WindowServer asynchronously. Poll briefly
        // so this verifies the server-side layer rather than racing AppKit's
        // local `isVisible` state.
        var actualLayer: Int?
        var isOnScreen = false
        for _ in 0..<20 {
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionAll],
                kCGNullWindowID
            ) as? [[String: Any]]
            let recorderInfo = windowInfo?.first {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber
            }
            actualLayer = (recorderInfo?[kCGWindowLayer as String] as? NSNumber)?.intValue
            isOnScreen = panel.isRecorderOverlayOnScreen()
            if actualLayer == RecorderOverlayPanel.overlayLevel.rawValue, isOnScreen { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(actualLayer == RecorderOverlayPanel.overlayLevel.rawValue)
        #expect(isOnScreen)
    }

    @Test("A manually moved recorder keeps its position and restores its overlay policy")
    func restoresOverlayPolicyAfterManualMovement() async throws {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        let manuallyChosenFrame = panel.frame.offsetBy(dx: 37, dy: 19)
        panel.setFrame(manuallyChosenFrame, display: false)
        panel.level = .normal
        panel.collectionBehavior = []

        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared
        )
        try await Task.sleep(for: .milliseconds(550))

        #expect(panel.frame == manuallyChosenFrame)
        #expect(panel.level == RecorderOverlayPanel.overlayLevel)
        #expect(panel.collectionBehavior == RecorderOverlayPanel.overlayCollectionBehavior)
        #expect(panel.isVisible)
    }

    @Test("An inactive or sleeping session suppresses the recorder until every reason clears")
    func suppressesRecorderWhileSessionIsNotVisible() {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: NSWorkspace.shared
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: NSWorkspace.shared
        )

        #expect(panel.isRecorderPresented)
        #expect(!panel.isVisible)

        panel.reassertRecorderOverlay()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: NSWorkspace.shared
        )

        #expect(!panel.isVisible)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: NSWorkspace.shared
        )

        #expect(panel.isVisible)
    }

    @Test("A panel created after screen saver start inherits the existing suppression")
    func inheritsSuppressionThatStartedBeforePanelCreation() async throws {
        _ = RecorderOverlaySystemStateMonitor.shared
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            RecorderOverlaySystemStateMonitor.screenSaverDidStartNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        defer {
            center.postNotificationName(
                RecorderOverlaySystemStateMonitor.screenSaverDidStopNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        try await Task.sleep(for: .milliseconds(50))

        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()

        #expect(panel.isRecorderPresented)
        #expect(!panel.isVisible)

        center.postNotificationName(
            RecorderOverlaySystemStateMonitor.screenSaverDidStopNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("A geometry refresh requested while suppressed runs before the recorder resumes")
    func retainsPendingFramePreparationDuringSuppression() {
        let panel = FramePreparationTrackingPanel()
        defer { panel.close() }

        panel.presentRecorderOverlay()
        #expect(panel.preparationCount == 1)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: NSWorkspace.shared
        )
        panel.reassertRecorderOverlay(after: 0.1, prepareFrame: true)

        #expect(!panel.isVisible)
        #expect(panel.preparationCount == 1)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: NSWorkspace.shared
        )

        #expect(panel.isVisible)
        #expect(panel.preparationCount == 2)
    }

    @Test("An application activation restores the recorder overlay policy")
    func restoresOverlayPolicyAfterApplicationActivation() {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        panel.level = .normal
        panel.collectionBehavior = []

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared
        )

        #expect(panel.level == RecorderOverlayPanel.overlayLevel)
        #expect(panel.collectionBehavior == RecorderOverlayPanel.overlayCollectionBehavior)
        #expect(panel.isVisible)
    }

    @Test("A presented recorder is restored without relying on transient visibility")
    func reassertsPresentedRecorderAfterSpaceTransition() async throws {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        #expect(panel.isRecorderPresented)
        #expect(panel.isVisible)

        // A Space transition can temporarily remove an ordered window from
        // the visible window list even though the recorder should remain shown.
        panel.orderOut(nil)
        #expect(panel.isRecorderPresented)
        #expect(!panel.isVisible)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared
        )
        try await Task.sleep(for: .milliseconds(550))

        #expect(panel.isVisible)
    }

    @Test("A newly presented recorder is reasserted while its full-screen Space settles")
    func reassertsNewRecorderAfterInitialPresentation() async throws {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        panel.orderOut(nil)
        #expect(panel.isRecorderPresented)
        #expect(!panel.isVisible)

        try await Task.sleep(for: .milliseconds(550))

        #expect(panel.isVisible)
    }

    @Test("Visibility recovery stops once WindowServer reports the recorder on screen")
    func stopsRecoveryAfterServerSideVisibilityReturns() async throws {
        let panel = VisibilityRecoveryTrackingPanel()
        defer { panel.close() }
        var visibilityChecks = 0
        var reattachments = 0
        panel.recorderOverlayOnScreenProvider = { _ in
            visibilityChecks += 1
            return visibilityChecks >= 2
        }
        panel.activeSpaceReattachmentHandler = { reattachments += 1 }

        panel.presentRecorderOverlay()
        try await Task.sleep(for: .milliseconds(100))

        #expect(visibilityChecks == 2)
        #expect(reattachments == 0)
    }

    @Test("A recorder still off screen after the grace check is reattached to the active Space")
    func reattachesRecorderThatRemainsOffScreen() async throws {
        let panel = VisibilityRecoveryTrackingPanel()
        defer { panel.close() }
        var reattachments = 0
        panel.recorderOverlayOnScreenProvider = { _ in false }
        panel.activeSpaceReattachmentHandler = { reattachments += 1 }

        panel.presentRecorderOverlay()
        try await Task.sleep(for: .milliseconds(100))

        #expect(reattachments == panel.visibilityRecoveryIntervals.count - 1)
    }

    @Test("Dismissing a recorder cancels pending server-side visibility recovery")
    func dismissalCancelsVisibilityRecovery() async throws {
        let panel = VisibilityRecoveryTrackingPanel()
        defer { panel.close() }
        var visibilityChecks = 0
        var reattachments = 0
        panel.recorderOverlayOnScreenProvider = { _ in
            visibilityChecks += 1
            return false
        }
        panel.activeSpaceReattachmentHandler = { reattachments += 1 }

        panel.presentRecorderOverlay()
        panel.dismissRecorderOverlay()
        try await Task.sleep(for: .milliseconds(100))

        #expect(visibilityChecks == 0)
        #expect(reattachments == 0)
        #expect(!panel.isVisible)
    }

    @Test("System suppression cancels pending server-side visibility recovery")
    func suppressionCancelsVisibilityRecovery() async throws {
        let panel = VisibilityRecoveryTrackingPanel()
        defer { panel.close() }
        var visibilityChecks = 0
        var reattachments = 0
        panel.recorderOverlayOnScreenProvider = { _ in
            visibilityChecks += 1
            return false
        }
        panel.activeSpaceReattachmentHandler = { reattachments += 1 }

        panel.presentRecorderOverlay()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: NSWorkspace.shared
        )
        try await Task.sleep(for: .milliseconds(100))

        #expect(visibilityChecks == 0)
        #expect(reattachments == 0)
        #expect(!panel.isVisible)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: NSWorkspace.shared
        )
    }

    @Test("Strong Space recovery preserves a manually selected frame")
    func activeSpaceReattachmentPreservesFrame() async throws {
        let panel = VisibilityRecoveryTrackingPanel()
        defer { panel.close() }
        panel.testRecoveryIntervals = [0.01, 0.01, 0.01]
        var visibilityChecks = 0
        panel.recorderOverlayOnScreenProvider = { _ in
            visibilityChecks += 1
            return visibilityChecks >= 3
        }

        panel.presentRecorderOverlay()
        let manuallyChosenFrame = NSRect(x: 71, y: 93, width: 160, height: 40)
        panel.setFrame(manuallyChosenFrame, display: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(panel.frame == manuallyChosenFrame)
        #expect(panel.collectionBehavior == RecorderOverlayPanel.overlayCollectionBehavior)
        #expect(panel.isVisible)
    }

    @Test("A dismissed recorder is not restored by a delayed Space callback")
    func doesNotRestoreDismissedRecorder() async throws {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        panel.dismissRecorderOverlay()
        panel.reassertRecorderOverlay()
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared
        )
        try await Task.sleep(for: .milliseconds(550))

        #expect(!panel.isRecorderPresented)
        #expect(!panel.isVisible)
    }
}
