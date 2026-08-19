import AppKit

enum RecorderFollowCorner: CaseIterable, Equatable {
    /// The recorder's top-left corner is nearest the pointer.
    case topLeft
    /// The recorder's top-right corner is nearest the pointer.
    case topRight
    /// The recorder's bottom-left corner is nearest the pointer.
    case bottomLeft
    /// The recorder's bottom-right corner is nearest the pointer.
    case bottomRight
}

struct RecorderFollowPlacement: Equatable {
    let frame: NSRect
    let corner: RecorderFollowCorner
    let isConstrained: Bool
}

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

    static func followPlacement(
        anchor: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        preferredCorner: RecorderFollowCorner = .topLeft,
        gap: CGFloat = 12,
        edgePadding: CGFloat = 8
    ) -> RecorderFollowPlacement {
        let safeFrame = visibleFrame.insetBy(dx: edgePadding, dy: edgePadding)
        let fittingSize = NSSize(
            width: min(panelSize.width, safeFrame.width),
            height: min(panelSize.height, safeFrame.height)
        )
        let corners = orderedFollowCorners(preferredCorner: preferredCorner)

        for corner in corners {
            let frame = followFrame(
                anchor: anchor,
                panelSize: fittingSize,
                corner: corner,
                gap: gap
            )
            if safeFrame.contains(frame) {
                return RecorderFollowPlacement(frame: frame, corner: corner, isConstrained: false)
            }
        }

        let corner = corners[0]
        let proposedFrame = followFrame(
            anchor: anchor,
            panelSize: fittingSize,
            corner: corner,
            gap: gap
        )
        return RecorderFollowPlacement(
            frame: constrained(proposedFrame, to: safeFrame),
            corner: corner,
            isConstrained: true
        )
    }

    private static func orderedFollowCorners(
        preferredCorner: RecorderFollowCorner
    ) -> [RecorderFollowCorner] {
        [preferredCorner] + RecorderFollowCorner.allCases.filter { $0 != preferredCorner }
    }

    private static func followFrame(
        anchor: NSPoint,
        panelSize: NSSize,
        corner: RecorderFollowCorner,
        gap: CGFloat
    ) -> NSRect {
        switch corner {
        case .topLeft:
            return NSRect(
                x: anchor.x + gap,
                y: anchor.y - gap - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
        case .topRight:
            return NSRect(
                x: anchor.x - gap - panelSize.width,
                y: anchor.y - gap - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
        case .bottomLeft:
            return NSRect(
                x: anchor.x + gap,
                y: anchor.y + gap,
                width: panelSize.width,
                height: panelSize.height
            )
        case .bottomRight:
            return NSRect(
                x: anchor.x - gap - panelSize.width,
                y: anchor.y + gap,
                width: panelSize.width,
                height: panelSize.height
            )
        }
    }

    private static func constrained(_ frame: NSRect, to boundary: NSRect) -> NSRect {
        NSRect(
            x: min(max(frame.minX, boundary.minX), boundary.maxX - frame.width),
            y: min(max(frame.minY, boundary.minY), boundary.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }
}
