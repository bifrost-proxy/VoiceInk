import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    let stateProvider: S
    let recorder: Recorder
    let assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    let usesFixedCanvas: Bool
    let onContentSizeChange: ((CGSize) -> Void)?
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @StateObject private var presentationModel: RecorderWindowPresentationModel<S>
    @State private var isTranscriptContentVisible = false

    init(
        stateProvider: S,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void,
        usesFixedCanvas: Bool = true,
        onContentSizeChange: ((CGSize) -> Void)? = nil
    ) {
        self.stateProvider = stateProvider
        self.recorder = recorder
        self.assistantSession = assistantSession
        self.onRecordButtonTapped = onRecordButtonTapped
        self.onCloseTapped = onCloseTapped
        self.onAssistantFollowUp = onAssistantFollowUp
        self.usesFixedCanvas = usesFixedCanvas
        self.onContentSizeChange = onContentSizeChange

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

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 184
    private let expandedWidth: CGFloat = 420
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    private var cornerRadius: CGFloat {
        hasVisibleTranscript || hasAssistantResponse || permissionGuidance != nil
            ? expandedCornerRadius : compactCornerRadius
    }

    private var separatorColor: Color {
        Color.primary.opacity(0.13)
    }

    private var presentation: RecorderWindowPresentation {
        presentationModel.value
    }

    // Keep the visible transcript while post-processing so status changes do not hide the user's text.
    private var hasVisibleTranscript: Bool {
        presentation.hasVisibleTranscript
    }

    private var hasAssistantResponse: Bool {
        presentation.assistantIsVisible
    }

    private var permissionGuidance: RecorderPermissionGuidance? {
        presentation.permissionGuidance
    }

    private var shouldShowCloseButton: Bool {
        permissionGuidance != nil
            || (hasAssistantResponse && presentation.recordingState == .idle && !presentation.assistantIsBusy)
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Group {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: presentation.recordingState,
                        action: onRecordButtonTapped
                    )
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: presentation.recordingState,
                recorder: recorder
            )

            Spacer(minLength: 0)

            RecorderModeButton(
                buttonSize: 22,
                padding: EdgeInsets()
            )
            .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if isTranscriptContentVisible && hasVisibleTranscript {
                RecorderLiveTranscript(stateProvider: stateProvider)
                Divider().background(separatorColor)
            }
        }
        .frame(height: hasVisibleTranscript ? 97 : 0)
        .clipped()
    }

    private var recorderContent: some View {
        VStack(spacing: 0) {
            if let permissionGuidance {
                RecorderPermissionGuidanceView(
                    guidance: permissionGuidance,
                    onAction: onRecordButtonTapped
                )
                Divider().background(separatorColor)
            } else if hasAssistantResponse {
                RecorderAssistantPanel(
                    stateProvider: stateProvider,
                    session: assistantSession,
                    showLiveTranscript: showLiveTranscript,
                    onSend: onAssistantFollowUp
                )
                Divider().background(separatorColor)
            } else {
                transcriptSection
            }
            controlBar
        }
        .frame(
            width: permissionGuidance != nil
                ? expandedWidth
                : (hasAssistantResponse ? assistantWidth : (hasVisibleTranscript ? expandedWidth : compactWidth))
        )
        .background {
            RecorderGlassSurface(cornerRadius: cornerRadius)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: presentation)
    }

    var body: some View {
        Group {
            if usesFixedCanvas {
                recorderContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                recorderContent
                    .fixedSize()
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            guard !usesFixedCanvas, size.width > 0, size.height > 0 else { return }
            onContentSizeChange?(size)
        }
        .onChange(of: showLiveTranscript) { _, isEnabled in
            presentationModel.updateShowLiveTranscript(isEnabled)
        }
        .task(id: hasVisibleTranscript) {
            guard hasVisibleTranscript else {
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
}
