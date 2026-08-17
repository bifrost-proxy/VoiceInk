import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
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

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 184
    private let expandedWidth: CGFloat = 420
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

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

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && presentation.recordingState == .idle && !presentation.assistantIsBusy
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
                Divider().background(Color.white.opacity(0.15))
            }
        }
        .frame(height: hasVisibleTranscript ? 97 : 0)
        .clipped()
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                RecorderAssistantPanel(
                    stateProvider: stateProvider,
                    session: assistantSession,
                    showLiveTranscript: showLiveTranscript,
                    onSend: onAssistantFollowUp
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            controlBar
        }
        .frame(width: hasAssistantResponse ? assistantWidth : (hasVisibleTranscript ? expandedWidth : compactWidth))
        .background(Color.black)
        .clipShape(
            RoundedRectangle(
                cornerRadius: hasVisibleTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
                style: .continuous)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: presentation)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
