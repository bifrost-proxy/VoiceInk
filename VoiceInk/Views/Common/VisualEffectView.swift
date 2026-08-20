import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        cornerRadius: CGFloat = 0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        Self.configure(
            visualEffectView,
            material: material,
            blendingMode: blendingMode,
            cornerRadius: cornerRadius
        )
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        Self.configure(
            visualEffectView,
            material: material,
            blendingMode: blendingMode,
            cornerRadius: cornerRadius
        )
    }

    static func configure(
        _ visualEffectView: NSVisualEffectView,
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        cornerRadius: CGFloat
    ) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        if cornerRadius > 0 {
            // Behind-window material is generated outside the normal layer contents, so
            // AppKit's material mask is required in addition to layer clipping.
            if visualEffectView.maskImage?.capInsets.top != cornerRadius {
                visualEffectView.maskImage = roundedMaskImage(cornerRadius: cornerRadius)
            }
            visualEffectView.wantsLayer = true
            visualEffectView.layer?.cornerRadius = cornerRadius
            visualEffectView.layer?.cornerCurve = .continuous
            visualEffectView.layer?.masksToBounds = true
        } else {
            visualEffectView.maskImage = nil
            visualEffectView.layer?.cornerRadius = 0
            visualEffectView.layer?.masksToBounds = false
        }
    }

    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = ceil(cornerRadius * 2) + 1
        let image = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}
