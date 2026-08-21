import AppKit
import SwiftUI

class MiniRecorderPanel: RecorderOverlayPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    private func configurePanel() {
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    static func calculateWindowMetrics() -> NSRect {
        guard let screen = RecorderWindowGeometry.targetScreen() else {
            return NSRect(x: 0, y: 0, width: 540, height: 430)
        }
        return RecorderWindowGeometry.miniWindowFrame(in: screen.visibleFrame)
    }

    func show() {
        presentRecorderOverlay()
    }

    @objc private func handleScreenParametersChange() {
        reassertRecorderOverlay(after: 0.1)
    }

    override func prepareRecorderOverlayForPresentation() {
        setFrame(MiniRecorderPanel.calculateWindowMetrics(), display: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

}
