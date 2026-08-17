import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    let stateProvider: S
    let recorder: Recorder
    let assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @StateObject private var presentationModel: RecorderWindowPresentationModel<S>
    @State private var isTranscriptContentVisible = false

    init(
        stateProvider: S,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.stateProvider = stateProvider
        self.recorder = recorder
        self.assistantSession = assistantSession
        self.onRecordButtonTapped = onRecordButtonTapped
        self.onCloseTapped = onCloseTapped
        self.onAssistantFollowUp = onAssistantFollowUp

        let defaults = UserDefaults.standard
        let initialShowLiveTranscript = defaults.object(
            forKey: RecorderDisplaySettingsKeys.showLiveTranscript
        ) == nil ? true : defaults.bool(forKey: RecorderDisplaySettingsKeys.showLiveTranscript)
        _presentationModel = StateObject(
            wrappedValue: RecorderWindowPresentationModel(
                stateProvider: stateProvider,
                assistantSession: assistantSession,
                showLiveTranscript: initialShowLiveTranscript
            )
        )
    }

    // MARK: - Display State

    private enum DisplayState: Equatable {
        case collapsed
        case active
        case liveText
        case assistant
    }

    private var presentation: RecorderWindowPresentation {
        presentationModel.value
    }

    private var displayState: DisplayState {
        if presentation.assistantIsVisible {
            return .assistant
        }

        switch presentation.recordingState {
        case .recording, .transcribing, .enhancing:
            return presentation.hasVisibleTranscript ? .liveText : .active
        default:
            return .collapsed
        }
    }

    // MARK: - Screen Geometry

    private var notchWidth: CGFloat {
        guard let screen = NSScreen.main else { return 180 }
        if let left = screen.auxiliaryTopLeftArea?.width,
            let right = screen.auxiliaryTopRightArea?.width
        {
            return screen.frame.width - left - right
        }
        return 180
    }

    private var notchHeight: CGFloat {
        guard let screen = NSScreen.main else { return 37 }
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
    }

    // MARK: - Layout Constants

    private let recordingSideExpansion: CGFloat = 90
    private let transcriptSideExpansion: CGFloat = 110
    private let assistantSideExpansion: CGFloat = 230
    private let activeHeightBonus: CGFloat = 6
    private let transcriptPanelHeight: CGFloat = 97
    private let assistantPanelHeight: CGFloat = 320

    private var mainRowHeight: CGFloat { notchHeight + activeHeightBonus }

    // MARK: - Pill Dimensions

    private var pillWidth: CGFloat {
        switch displayState {
        case .collapsed: return notchWidth
        case .active: return notchWidth + recordingSideExpansion * 2
        case .liveText: return notchWidth + transcriptSideExpansion * 2
        case .assistant: return notchWidth + assistantSideExpansion * 2
        }
    }

    private var pillHeight: CGFloat {
        switch displayState {
        case .collapsed: return 0
        case .active: return mainRowHeight
        case .liveText: return mainRowHeight + transcriptPanelHeight
        case .assistant: return mainRowHeight + assistantPanelHeight
        }
    }

    private var sideExpansion: CGFloat {
        switch displayState {
        case .liveText:
            return transcriptSideExpansion
        case .assistant:
            return assistantSideExpansion
        case .active, .collapsed:
            return recordingSideExpansion
        }
    }

    private var sideEdgePadding: CGFloat {
        displayState == .liveText || displayState == .assistant ? 20 : 16
    }

    private var shouldShowCloseButton: Bool {
        displayState == .assistant && presentation.recordingState == .idle && !presentation.assistantIsBusy
    }

    // MARK: - Animation

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    private var pillAnimation: Animation {
        displayState == .collapsed ? collapseAnimation : expandAnimation
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            pill.position(x: geo.size.width / 2, y: pillHeight / 2)
        }
        .animation(pillAnimation, value: displayState)
        .onChange(of: showLiveTranscript) { _, isEnabled in
            presentationModel.updateShowLiveTranscript(isEnabled)
        }
        .task(id: presentation.hasVisibleTranscript) {
            guard presentation.hasVisibleTranscript else {
                isTranscriptContentVisible = false
                return
            }
            try? await Task.sleep(
                nanoseconds: RecorderWindowTransitionPolicy.transcriptRevealDelayMilliseconds * 1_000_000
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: RecorderWindowTransitionPolicy.transcriptFadeDuration)) {
                isTranscriptContentVisible = true
            }
        }
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 0) {
            mainRow
            liveTextPanel
            assistantPanel
        }
        .frame(width: pillWidth, height: pillHeight)
        .background(Color.black)
        .clipShape(
            NotchShape(
                topCornerRadius: displayState == .liveText ? 12 : 8,
                bottomCornerRadius: displayState == .liveText || displayState == .assistant ? 22 : 16
            )
        )
    }

    // MARK: - Main Row

    private var mainRow: some View {
        ZStack {
            Color.clear

            HStack(spacing: 14) {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: presentation.recordingState,
                        action: onRecordButtonTapped
                    )
                }
                RecorderModeButton(buttonSize: 20, padding: EdgeInsets())
                Spacer(minLength: 0)
            }
            .padding(.leading, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RecorderStatusDisplay(
                    currentState: presentation.recordingState,
                    recorder: recorder,
                    menuBarHeight: notchHeight
                )
            }
            .padding(.trailing, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )
        }
        .frame(height: mainRowHeight)
    }

    // MARK: - Live Text Panel

    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if isTranscriptContentVisible && displayState == .liveText {
                Divider().background(Color.white.opacity(0.15))
                RecorderLiveTranscript(stateProvider: stateProvider)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    private var assistantPanel: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
                Divider().background(Color.white.opacity(0.15))
                RecorderAssistantPanel(
                    stateProvider: stateProvider,
                    session: assistantSession,
                    showLiveTranscript: showLiveTranscript,
                    onSend: onAssistantFollowUp
                )
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .clipped()
    }
}
