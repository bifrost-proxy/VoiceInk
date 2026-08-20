import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    final class MaterialView: NSVisualEffectView {
        var materialCornerRadius: CGFloat = 0
        private var maskedSize: NSSize = .zero
        private var maskedCornerRadius: CGFloat = 0

        override func layout() {
            super.layout()
            updateMaterialMaskIfNeeded()
        }

        func updateMaterialMaskIfNeeded() {
            let size = bounds.size
            guard materialCornerRadius > 0, size.width > 0, size.height > 0 else {
                maskImage = nil
                maskedSize = .zero
                maskedCornerRadius = 0
                return
            }
            guard size != maskedSize || materialCornerRadius != maskedCornerRadius else { return }

            maskImage = VisualEffectView.roundedMaskImage(
                size: size,
                cornerRadius: materialCornerRadius
            )
            maskedSize = size
            maskedCornerRadius = materialCornerRadius
        }
    }

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
        let visualEffectView = MaterialView()
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
            if let materialView = visualEffectView as? MaterialView {
                materialView.materialCornerRadius = cornerRadius
                materialView.updateMaterialMaskIfNeeded()
            } else if visualEffectView.bounds.width > 0, visualEffectView.bounds.height > 0 {
                visualEffectView.maskImage = roundedMaskImage(
                    size: visualEffectView.bounds.size,
                    cornerRadius: cornerRadius
                )
            }
            visualEffectView.wantsLayer = true
            visualEffectView.layer?.cornerRadius = cornerRadius
            visualEffectView.layer?.cornerCurve = .continuous
            visualEffectView.layer?.masksToBounds = true
        } else {
            if let materialView = visualEffectView as? MaterialView {
                materialView.materialCornerRadius = 0
                materialView.updateMaterialMaskIfNeeded()
            } else {
                visualEffectView.maskImage = nil
            }
            visualEffectView.layer?.cornerRadius = 0
            visualEffectView.layer?.masksToBounds = false
        }
    }

    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let maskLayer = CALayer()
            maskLayer.frame = rect
            maskLayer.backgroundColor = NSColor.white.cgColor
            maskLayer.cornerRadius = min(cornerRadius, min(rect.width, rect.height) / 2)
            maskLayer.cornerCurve = .continuous
            maskLayer.masksToBounds = true
            maskLayer.contentsScale = 1
            maskLayer.render(in: context)
            return true
        }
    }
}
