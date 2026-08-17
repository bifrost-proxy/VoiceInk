import AppKit
import SwiftUI

class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
        isFloatingPanel = true
        canHide = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
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
        let metrics = MiniRecorderPanel.calculateWindowMetrics()
        setFrame(metrics, display: true)
        orderFrontRegardless()
    }

    @objc private func handleActiveSpaceChange() {
        reanchorIfVisible(after: 0.12)
    }

    @objc private func handleScreenParametersChange() {
        reanchorIfVisible(after: 0.1)
    }

    private func reanchorIfVisible(after delay: TimeInterval) {
        guard isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isVisible else { return }
            self.setFrame(MiniRecorderPanel.calculateWindowMetrics(), display: true)
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

}
