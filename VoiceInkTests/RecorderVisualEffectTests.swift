import AppKit
import Testing
@testable import VoiceInk

@MainActor
struct RecorderVisualEffectTests {
    @Test("Recorder material clips its native backdrop to continuous rounded corners")
    func clipsNativeBackdropToRoundedCorners() throws {
        let view = VisualEffectView.MaterialView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 137)
        )

        VisualEffectView.configure(
            view,
            material: .popover,
            blendingMode: .behindWindow,
            cornerRadius: 14
        )

        #expect(view.wantsLayer)
        #expect(view.layer?.cornerRadius == 14)
        #expect(view.layer?.cornerCurve == .continuous)
        #expect(view.layer?.masksToBounds == true)
        let maskImage = try #require(view.maskImage)
        #expect(maskImage.size == view.bounds.size)
        #expect(maskImage.capInsets.top == 0)
        #expect(maskImage.capInsets.left == 0)
        #expect(maskImage.capInsets.bottom == 0)
        #expect(maskImage.capInsets.right == 0)

        let bitmap = try #require(maskImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let cornerAlpha = try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent
        let centerAlpha = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        ).alphaComponent
        #expect(cornerAlpha == 0)
        #expect(centerAlpha == 1)

        let ellipticalMask = NSImage(size: maskImage.size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            return true
        }
        let ellipticalBitmap = try #require(
            ellipticalMask.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        )
        let continuousShoulderAlpha = try #require(bitmap.colorAt(x: 11, y: 0)).alphaComponent
        let ellipticalShoulderAlpha = try #require(
            ellipticalBitmap.colorAt(x: 11, y: 0)
        ).alphaComponent
        #expect(continuousShoulderAlpha + 0.2 < ellipticalShoulderAlpha)
    }

    @Test("Recorder material rebuilds its mask when the preview bounds change")
    func rebuildsMaskForUpdatedBounds() throws {
        let view = VisualEffectView.MaterialView(
            frame: NSRect(x: 0, y: 0, width: 184, height: 40)
        )
        VisualEffectView.configure(
            view,
            material: .popover,
            blendingMode: .behindWindow,
            cornerRadius: 20
        )
        let compactMask = try #require(view.maskImage)
        #expect(compactMask.size == NSSize(width: 184, height: 40))

        view.setFrameSize(NSSize(width: 420, height: 137))
        view.layout()

        let expandedMask = try #require(view.maskImage)
        #expect(expandedMask !== compactMask)
        #expect(expandedMask.size == NSSize(width: 420, height: 137))
    }

    @Test("Unrounded materials do not retain a stale clipping mask")
    func clearsNativeBackdropMaskWithoutCornerRadius() {
        let view = VisualEffectView.MaterialView(
            frame: NSRect(x: 0, y: 0, width: 184, height: 40)
        )

        VisualEffectView.configure(
            view,
            material: .popover,
            blendingMode: .behindWindow,
            cornerRadius: 14
        )
        VisualEffectView.configure(
            view,
            material: .sidebar,
            blendingMode: .withinWindow,
            cornerRadius: 0
        )

        #expect(view.layer?.cornerRadius == 0)
        #expect(view.layer?.masksToBounds == false)
        #expect(view.maskImage == nil)
    }

    @Test("Existing unrounded materials remain non-layer-backed")
    func leavesUnroundedMaterialsUnlayered() {
        let view = VisualEffectView.MaterialView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        VisualEffectView.configure(
            view,
            material: .sidebar,
            blendingMode: .withinWindow,
            cornerRadius: 0
        )

        #expect(view.wantsLayer == false)
        #expect(view.layer == nil)
        #expect(view.maskImage == nil)
    }
}
