import AppKit
import Testing
@testable import VoiceInk

@MainActor
struct RecorderVisualEffectTests {
    @Test("Recorder material clips its native backdrop to continuous rounded corners")
    func clipsNativeBackdropToRoundedCorners() throws {
        let view = NSVisualEffectView()

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
        #expect(maskImage.capInsets.top == 14)
        #expect(maskImage.capInsets.left == 14)
        #expect(maskImage.capInsets.bottom == 14)
        #expect(maskImage.capInsets.right == 14)
        #expect(maskImage.resizingMode == .stretch)

        let bitmap = try #require(maskImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let cornerAlpha = try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent
        let centerAlpha = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        ).alphaComponent
        #expect(cornerAlpha == 0)
        #expect(centerAlpha == 1)
    }

    @Test("Unrounded materials do not retain a stale clipping mask")
    func clearsNativeBackdropMaskWithoutCornerRadius() {
        let view = NSVisualEffectView()

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
        let view = NSVisualEffectView()

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
