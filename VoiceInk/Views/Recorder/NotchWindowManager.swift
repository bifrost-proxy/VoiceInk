import AppKit
import SwiftUI

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?
    private let geometry = NotchRecorderGeometry()

    private let makeView: (NotchRecorderGeometry) -> AnyView

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.makeView = { geometry in
            AnyView(
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    geometry: geometry,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            )
        }
    }

    func show() {
        if panel == nil { initializeWindow() }
        panel?.show()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        let metrics = NotchRecorderPanel.calculateWindowMetrics()
        geometry.update(notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        newPanel.onMetricsChange = { [weak geometry] metrics in
            geometry?.update(notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        }
        let view = makeView(geometry)
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

}
