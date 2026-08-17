import AppKit

enum RecorderWindowGeometry {
    static func screenIndex(
        containing point: NSPoint,
        in frames: [NSRect],
        fallbackIndex: Int? = nil
    ) -> Int? {
        if let matchingIndex = frames.firstIndex(where: { $0.contains(point) }) {
            return matchingIndex
        }
        if let fallbackIndex, frames.indices.contains(fallbackIndex) {
            return fallbackIndex
        }
        return frames.indices.first
    }

    static func targetScreen(
        mouseLocation: NSPoint = NSEvent.mouseLocation,
        screens: [NSScreen] = NSScreen.screens,
        mainScreen: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        let fallbackIndex = mainScreen.flatMap { mainScreen in
            screens.firstIndex { $0 === mainScreen }
        }
        guard let index = screenIndex(
            containing: mouseLocation,
            in: screens.map(\.frame),
            fallbackIndex: fallbackIndex
        ) else { return nil }
        return screens[index]
    }

    static func miniWindowFrame(
        in visibleFrame: NSRect,
        size: NSSize = NSSize(width: 540, height: 430),
        bottomPadding: CGFloat = 24
    ) -> NSRect {
        NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + bottomPadding,
            width: size.width,
            height: size.height
        )
    }
}
