import AppKit
import SwiftUI
import Testing
@testable import VoiceInk

@MainActor
struct RecorderVisualEffectTests {
    @Test("Permission recorder leaves its expanded window corners transparent")
    func leavesExpandedRecorderCornersTransparent() throws {
        let backdrop = Color(red: 0.24, green: 0.52, blue: 0.78)
        let provider = RecorderVisualTestProvider()
        provider.recordingPermissionGuidance = .required(.accessibility)
        let recorder = MiniRecorderView(
            stateProvider: provider,
            recorder: Recorder(),
            assistantSession: AssistantSession(),
            onRecordButtonTapped: {},
            onCloseTapped: {},
            onAssistantFollowUp: { _ in }
        )
        let renderer = ImageRenderer(
            content: ZStack {
                backdrop
                recorder.frame(width: 540, height: 430)
            }
            .frame(width: 620, height: 510)
        )
        renderer.scale = 1

        let image = try #require(renderer.nsImage)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let untouchedBackdrop = try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        let cornerCoordinates = [(100, 40), (519, 40), (100, 234), (519, 234)]

        for (x, y) in cornerCoordinates {
            let exteriorCorner = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            #expect(abs(exteriorCorner.redComponent - untouchedBackdrop.redComponent) < 0.01)
            #expect(abs(exteriorCorner.greenComponent - untouchedBackdrop.greenComponent) < 0.01)
            #expect(abs(exteriorCorner.blueComponent - untouchedBackdrop.blueComponent) < 0.01)
        }
    }

    @Test("Recorder glass leaves pixels outside its rounded corners unchanged")
    func leavesRoundedCornerExteriorTransparent() throws {
        let backdrop = Color(red: 0.24, green: 0.52, blue: 0.78)
        let renderer = ImageRenderer(
            content: ZStack {
                backdrop
                RecorderGlassSurface(cornerRadius: 14)
                    .frame(width: 420, height: 195)
            }
            .frame(width: 500, height: 275)
        )
        renderer.scale = 1

        let image = try #require(renderer.nsImage)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let untouchedBackdrop = try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        let exteriorCorner = try #require(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.sRGB))

        #expect(abs(exteriorCorner.redComponent - untouchedBackdrop.redComponent) < 0.01)
        #expect(abs(exteriorCorner.greenComponent - untouchedBackdrop.greenComponent) < 0.01)
        #expect(abs(exteriorCorner.blueComponent - untouchedBackdrop.blueComponent) < 0.01)
    }

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

@MainActor
private final class RecorderVisualTestProvider: ObservableObject, RecorderStateProvider {
    @Published var recordingState: RecordingState = .idle
    @Published var partialTranscript = ""
    @Published var recordingPermissionGuidance: RecorderPermissionGuidance?
}
