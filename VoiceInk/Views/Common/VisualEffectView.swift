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
            visualEffectView.wantsLayer = true
            visualEffectView.layer?.cornerRadius = cornerRadius
            visualEffectView.layer?.cornerCurve = .continuous
            visualEffectView.layer?.masksToBounds = true
        } else {
            visualEffectView.layer?.cornerRadius = 0
            visualEffectView.layer?.masksToBounds = false
        }
    }
}
