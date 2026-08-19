import AppKit
import Testing
@testable import VoiceInk

struct RecorderWindowGeometryTests {
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
        #expect(visibleFrame.insetBy(dx: 8, dy: 8).contains(placement.frame))
    }
}
