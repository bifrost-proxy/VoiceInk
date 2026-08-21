import AppKit
import SwiftUI

@MainActor
final class FollowWindowManager {
    private var windowController: NSWindowController?
    private var panel: FollowRecorderPanel?
    private let makeView: (@escaping (CGSize) -> Void) -> AnyView

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.makeView = { onContentSizeChange in
            AnyView(
                MiniRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    usesFixedCanvas: false,
                    onContentSizeChange: onContentSizeChange
                )
            )
        }
    }

    func show(anchor: NSPoint) {
        if panel == nil { initializeWindow() }
        panel?.show(anchor: anchor)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

    private func initializeWindow() {
        destroyWindow()
        let panel = FollowRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 184, height: 40))
        let hostingController = NSHostingController(
            rootView: makeView { [weak panel] size in
                panel?.updateContentSize(size)
            }
        )
        panel.contentView = hostingController.view
        self.panel = panel
        windowController = NSWindowController(window: panel)
    }
}

final class FollowRecorderPanel: NSPanel {
    /// Reserve room for the widest and tallest supported recorder presentation
    /// before showing the compact control bar. This keeps a recorder opened
    /// near a bottom-aligned input from growing back across that input when
    /// live text, permission guidance, or an assistant response appears.
    private static let expandedPresentationSize = NSSize(width: 520, height: 430)

    private var anchor: NSPoint?
    private var contentSize = NSSize(width: 184, height: 40)
    private var preferredCorner = RecorderFollowCorner.topLeft
    private(set) var usesManualPlacement = false
    private var isApplyingManagedFrame = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing backingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: backingType,
            defer: flag
        )
        isFloatingPanel = true
        canHide = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillMove),
            name: NSWindow.willMoveNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    convenience init(contentRect: NSRect) {
        self.init(contentRect: contentRect, styleMask: [], backing: .buffered, defer: false)
    }

    func show(anchor: NSPoint) {
        self.anchor = anchor
        usesManualPlacement = false
        choosePreferredCorner(reserving: Self.expandedPresentationSize)
        applyPlacement()
        orderFrontRegardless()
    }

    func updateContentSize(_ size: CGSize) {
        let measuredSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard measuredSize.width > 0, measuredSize.height > 0, measuredSize != contentSize else { return }
        contentSize = measuredSize
        guard anchor != nil else { return }
        if usesManualPlacement {
            applyManualPlacement()
        } else {
            applyPlacement()
        }
    }

    @objc private func handleScreenParametersChange() {
        guard isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.usesManualPlacement {
                self.applyManualPlacement()
            } else {
                self.choosePreferredCorner(reserving: Self.expandedPresentationSize)
                self.applyPlacement()
            }
        }
    }

    @objc private func handleWindowWillMove() {
        guard !isApplyingManagedFrame else { return }
        usesManualPlacement = true
    }

    @objc private func handleWindowDidMove() {
        guard usesManualPlacement, !isApplyingManagedFrame else { return }
        applyManualPlacement()
    }

    private func choosePreferredCorner(reserving reservedSize: NSSize) {
        guard let anchor else { return }
        let visibleFrame = visibleFrame(for: anchor)
        let placement = RecorderWindowGeometry.followPlacement(
            anchor: anchor,
            panelSize: reservedSize,
            visibleFrame: visibleFrame
        )
        preferredCorner = placement.corner
    }

    private func applyPlacement() {
        guard let anchor else { return }
        let visibleFrame = visibleFrame(for: anchor)
        let placement = RecorderWindowGeometry.followPlacement(
            anchor: anchor,
            panelSize: contentSize,
            visibleFrame: visibleFrame,
            preferredCorner: preferredCorner
        )
        preferredCorner = placement.corner
        setManagedFrame(placement.frame)
    }

    private func applyManualPlacement() {
        let referencePoint = NSPoint(x: frame.midX, y: frame.midY)
        let visibleFrame = visibleFrame(for: referencePoint)
        let placement = RecorderWindowGeometry.manuallyPositionedFollowFrame(
            currentFrame: frame,
            panelSize: contentSize,
            visibleFrame: visibleFrame
        )
        guard placement != frame else { return }
        setManagedFrame(placement)
    }

    private func setManagedFrame(_ frame: NSRect) {
        isApplyingManagedFrame = true
        defer { isApplyingManagedFrame = false }
        setFrame(frame, display: true)
    }

    private func visibleFrame(for anchor: NSPoint) -> NSRect {
        RecorderWindowGeometry.targetScreen(mouseLocation: anchor)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: contentSize)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
