import AppKit
import SwiftUI

/// The complete background applied to recorder content. Keep this surface free of
/// outer shadows so pixels outside the rounded glass remain fully transparent.
struct RecorderGlassSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RecorderGlassBackground(cornerRadius: cornerRadius)
    }
}

struct RecorderGlassBackground: View {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        colorScheme == .dark
            ? Color(red: 0.035, green: 0.04, blue: 0.05).opacity(0.58)
            : Color.white.opacity(0.62)
    }

    private var border: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.12)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            VisualEffectView(
                material: .popover,
                blendingMode: .behindWindow,
                cornerRadius: cornerRadius
            )
            tint
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(border, lineWidth: 0.7))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
