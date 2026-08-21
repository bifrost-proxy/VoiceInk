import AppKit
import Testing
@testable import VoiceInk

@MainActor
struct RecorderOverlayPanelTests {
    @Test("Every recorder style can join other applications in full screen")
    func recorderPanelsUseCrossApplicationOverlayPolicy() {
        let panels: [RecorderOverlayPanel] = [
            MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)),
            FollowRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 184, height: 40)),
            NotchRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 430)),
        ]
        defer { panels.forEach { $0.close() } }

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

    @Test("A dismissed recorder is not restored by a delayed Space callback")
    func doesNotRestoreDismissedRecorder() {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430)
        )
        defer { panel.close() }

        panel.presentRecorderOverlay()
        panel.dismissRecorderOverlay()
        panel.reassertRecorderOverlay()

        #expect(!panel.isRecorderPresented)
        #expect(!panel.isVisible)
    }
}
