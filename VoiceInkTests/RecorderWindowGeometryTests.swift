import AppKit
import Testing
@testable import VoiceInk

struct RecorderWindowGeometryTests {
    @MainActor
    @Test("Allows the follow recorder background to start a manual window drag")
    func configuresFollowRecorderForBackgroundDragging() {
        let panel = FollowRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 184, height: 40)
        )
        defer { panel.close() }

        #expect(panel.isMovable)
        #expect(panel.isMovableByWindowBackground)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.usesManualPlacement)

        NotificationCenter.default.post(name: NSWindow.willMoveNotification, object: panel)

        #expect(panel.usesManualPlacement)
    }

    @Test("Selects the screen containing the mouse")
    func selectsMouseScreen() {
        let frames = [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),
            NSRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]

        #expect(
            RecorderWindowGeometry.screenIndex(
                containing: NSPoint(x: 2400, y: 700),
                in: frames
            ) == 1
        )
    }

    @Test("Supports secondary screens with negative coordinates")
    func selectsNegativeCoordinateScreen() {
        let frames = [
            NSRect(x: 0, y: 0, width: 1728, height: 1117),
            NSRect(x: -1920, y: -120, width: 1920, height: 1080),
        ]

        #expect(
            RecorderWindowGeometry.screenIndex(
                containing: NSPoint(x: -800, y: 300),
                in: frames
            ) == 1
        )
    }

    @Test("Falls back to the main screen when the mouse is outside every display")
    func fallsBackOutsideDisplays() {
        let frames = [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),
            NSRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]

        #expect(
            RecorderWindowGeometry.screenIndex(
                containing: NSPoint(x: -50, y: 3000),
                in: frames,
                fallbackIndex: 1
            ) == 1
        )
    }

    @Test("Uses the first screen when no explicit fallback is available")
    func fallsBackToFirstScreen() {
        let frames = [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),
            NSRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]

        #expect(
            RecorderWindowGeometry.screenIndex(
                containing: NSPoint(x: -50, y: 3000),
                in: frames
            ) == 0
        )
    }

    @Test("Selects deterministically when the mouse lies on a shared edge")
    func selectsSharedEdgeDeterministically() {
        let frames = [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),
            NSRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]

        #expect(
            RecorderWindowGeometry.screenIndex(
                containing: NSPoint(x: 1920, y: 500),
                in: frames
            ) == 1
        )
    }

    @Test("Centers the mini recorder at the bottom of the selected visible frame")
    func calculatesMiniWindowFrame() {
        let visibleFrame = NSRect(x: -1920, y: 30, width: 1920, height: 1050)

        let frame = RecorderWindowGeometry.miniWindowFrame(in: visibleFrame)

        #expect(frame == NSRect(x: -1230, y: 54, width: 540, height: 430))
    }

    @Test("Places the follow recorder below and to the right of the pointer by default")
    func placesFollowRecorderAtPreferredCorner() {
        let placement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: 500, y: 500),
            panelSize: NSSize(width: 184, height: 40),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(placement.corner == .topLeft)
        #expect(placement.frame == NSRect(x: 512, y: 448, width: 184, height: 40))
        #expect(!placement.isConstrained)
    }

    @Test("Flips the follow recorder left when the pointer is near the right edge")
    func flipsFollowRecorderAtRightEdge() {
        let placement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: 980, y: 500),
            panelSize: NSSize(width: 184, height: 40),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(placement.corner == .topRight)
        #expect(placement.frame == NSRect(x: 784, y: 448, width: 184, height: 40))
    }

    @Test("Flips the follow recorder above when the pointer is near the bottom edge")
    func flipsFollowRecorderAtBottomEdge() {
        let placement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: 500, y: 25),
            panelSize: NSSize(width: 184, height: 40),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(placement.corner == .bottomLeft)
        #expect(placement.frame == NSRect(x: 512, y: 37, width: 184, height: 40))
    }

    @Test("Keeps the follow recorder away from every screen edge")
    func keepsFollowRecorderAwayFromScreenEdges() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let panelSize = NSSize(width: 184, height: 40)

        let bottomPlacement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: 500, y: visibleFrame.minY),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        let topPlacement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: 500, y: visibleFrame.maxY),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        let leftPlacement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: visibleFrame.minX, y: 400),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        let rightPlacement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: visibleFrame.maxX, y: 400),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        let edgePadding = RecorderWindowGeometry.followEdgePadding
        #expect(bottomPlacement.frame.minY == visibleFrame.minY + edgePadding)
        #expect(topPlacement.frame.maxY == visibleFrame.maxY - edgePadding)
        #expect(leftPlacement.frame.minX == visibleFrame.minX + edgePadding)
        #expect(rightPlacement.frame.maxX == visibleFrame.maxX - edgePadding)
    }

    @Test("Reserves expansion space before placing a compact follow recorder near the bottom")
    func reservesExpansionSpaceBeforeShowingCompactFollowRecorder() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let anchor = NSPoint(x: 500, y: 100)
        let expansionPlacement = RecorderWindowGeometry.followPlacement(
            anchor: anchor,
            panelSize: NSSize(width: 520, height: 430),
            visibleFrame: visibleFrame
        )
        let compactPlacement = RecorderWindowGeometry.followPlacement(
            anchor: anchor,
            panelSize: NSSize(width: 184, height: 40),
            visibleFrame: visibleFrame,
            preferredCorner: expansionPlacement.corner
        )

        #expect(expansionPlacement.corner == .bottomLeft)
        #expect(compactPlacement.corner == .bottomLeft)
        #expect(compactPlacement.frame.minY > anchor.y)
    }

    @Test("Constrains an oversized follow recorder to the visible frame")
    func constrainsOversizedFollowRecorder() {
        let visibleFrame = NSRect(x: -400, y: 20, width: 300, height: 180)
        let placement = RecorderWindowGeometry.followPlacement(
            anchor: NSPoint(x: -150, y: 100),
            panelSize: NSSize(width: 600, height: 400),
            visibleFrame: visibleFrame
        )

        #expect(placement.isConstrained)
        let edgePadding = RecorderWindowGeometry.followEdgePadding
        #expect(visibleFrame.insetBy(dx: edgePadding, dy: edgePadding).contains(placement.frame))
    }

    @Test("Keeps the dragged control bar stable when follow content expands")
    func manuallyResizesFollowRecorderAroundBottomCenter() {
        let currentFrame = NSRect(x: 400, y: 200, width: 184, height: 40)

        let resizedFrame = RecorderWindowGeometry.manuallyPositionedFollowFrame(
            currentFrame: currentFrame,
            panelSize: NSSize(width: 420, height: 137),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 900)
        )

        #expect(resizedFrame.midX == currentFrame.midX)
        #expect(resizedFrame.minY == currentFrame.minY)
        #expect(resizedFrame.size == NSSize(width: 420, height: 137))
    }

    @Test("Keeps a manually positioned follow recorder inside the visible screen")
    func constrainsManuallyPositionedFollowRecorder() {
        let visibleFrame = NSRect(x: -1_200, y: 20, width: 1_200, height: 780)

        let resizedFrame = RecorderWindowGeometry.manuallyPositionedFollowFrame(
            currentFrame: NSRect(x: -100, y: 10, width: 184, height: 40),
            panelSize: NSSize(width: 520, height: 430),
            visibleFrame: visibleFrame
        )

        let safeFrame = visibleFrame.insetBy(
            dx: RecorderWindowGeometry.followEdgePadding,
            dy: RecorderWindowGeometry.followEdgePadding
        )
        #expect(safeFrame.contains(resizedFrame))
        #expect(resizedFrame.maxX == safeFrame.maxX)
        #expect(resizedFrame.minY == safeFrame.minY)
    }

    @Test("Fits a manually positioned follow recorder on a very small screen")
    func fitsManualFollowRecorderToSmallScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 300, height: 180)

        let resizedFrame = RecorderWindowGeometry.manuallyPositionedFollowFrame(
            currentFrame: NSRect(x: 50, y: 50, width: 184, height: 40),
            panelSize: NSSize(width: 520, height: 430),
            visibleFrame: visibleFrame
        )

        #expect(
            resizedFrame.size == NSSize(
                width: visibleFrame.width - (2 * RecorderWindowGeometry.followEdgePadding),
                height: visibleFrame.height - (2 * RecorderWindowGeometry.followEdgePadding)
            )
        )
        #expect(
            visibleFrame.insetBy(
                dx: RecorderWindowGeometry.followEdgePadding,
                dy: RecorderWindowGeometry.followEdgePadding
            ).contains(resizedFrame)
        )
    }
}
