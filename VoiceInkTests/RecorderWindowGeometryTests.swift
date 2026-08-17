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
}
