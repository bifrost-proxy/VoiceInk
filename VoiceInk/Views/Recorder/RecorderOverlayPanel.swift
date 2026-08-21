import AppKit

/// Shared window policy for every recorder presentation.
///
/// Recorder panels are system-style overlays: they must remain available in
/// every Space, including full-screen Spaces owned by another application.
/// AppKit can temporarily report an ordered panel as not visible while Spaces
/// are transitioning, so presentation state is tracked independently from
/// `isVisible` and the overlay is explicitly reasserted after each transition.
class RecorderOverlayPanel: NSPanel {
    // Full-screen application windows can be ordered above menu/status-bar
    // levels. Use AppKit's dedicated high overlay level so the recorder stays
    // visible there without relying on an arbitrary offset.
    static let overlayLevel = NSWindow.Level.screenSaver
    static let overlayCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    private(set) var isRecorderPresented = false
    private var presentationGeneration: UInt = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        isFloatingPanel = true
        canHide = false
        level = Self.overlayLevel
        hidesOnDeactivate = false
        collectionBehavior = Self.overlayCollectionBehavior

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func presentRecorderOverlay() {
        presentationGeneration &+= 1
        isRecorderPresented = true
        reassertRecorderOverlay()

        // A panel first ordered while another app's full-screen Space is
        // settling can initially be attached to the previous Space. Reassert
        // after the same settling intervals used for an explicit Space change.
        scheduleReassertions(for: presentationGeneration)
    }

    func dismissRecorderOverlay() {
        presentationGeneration &+= 1
        isRecorderPresented = false
        orderOut(nil)
    }

    /// Subclasses update their screen-dependent frame before the panel is
    /// ordered above the newly active Space.
    func prepareRecorderOverlayForPresentation() {}

    func reassertRecorderOverlay() {
        guard isRecorderPresented else { return }
        level = Self.overlayLevel
        collectionBehavior = Self.overlayCollectionBehavior
        prepareRecorderOverlayForPresentation()
        orderFrontRegardless()
    }

    func reassertRecorderOverlay(after delay: TimeInterval) {
        guard isRecorderPresented else { return }
        let generation = presentationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.reassertRecorderOverlay()
        }
    }

    private func scheduleReassertions(for generation: UInt) {
        for delay in [0.1, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                    self.isRecorderPresented,
                    self.presentationGeneration == generation
                else {
                    return
                }
                self.reassertRecorderOverlay()
            }
        }
    }

    @objc private func handleActiveSpaceChange() {
        guard isRecorderPresented else { return }

        // Reorder once immediately after the Space changes and once after the
        // full-screen transition settles. The second pass closes the race in
        // which the destination app finishes ordering its full-screen window
        // after AppKit posts the active-Space notification.
        reassertRecorderOverlay(after: 0.1)
        reassertRecorderOverlay(after: 0.4)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
