import AppKit
import Testing
@testable import VoiceInk

@MainActor
struct RecorderVisualEffectTests {
    @Test("Recorder material clips its native backdrop to continuous rounded corners")
    func clipsNativeBackdropToRoundedCorners() {
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
    }
}
