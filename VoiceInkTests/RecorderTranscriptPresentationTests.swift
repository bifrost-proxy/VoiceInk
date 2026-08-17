import Combine
import Testing
@testable import VoiceInk

struct RecorderTranscriptPresentationTests {
    @Test func visibleTranscriptRemainsVisibleWhileTranscribingAndEnhancing() {
        for state in [RecordingState.recording, .transcribing, .enhancing] {
            #expect(
                RecorderTranscriptPresentation.shouldShow(
                    showLiveTranscript: true,
                    recordingState: state,
                    text: "已经显示的实时转写"
                )
            )
        }
    }

    @Test func hiddenSettingAndEmptyOrInactiveTranscriptsRemainHidden() {
        #expect(
            !RecorderTranscriptPresentation.shouldShow(
                showLiveTranscript: false,
                recordingState: .enhancing,
                text: "text"
            )
        )
        #expect(
            !RecorderTranscriptPresentation.shouldShow(
                showLiveTranscript: true,
                recordingState: .enhancing,
                text: ""
            )
        )
        #expect(
            !RecorderTranscriptPresentation.shouldShow(
                showLiveTranscript: true,
                recordingState: .idle,
                text: "text"
            )
        )
    }

    @Test func finalizedRawTranscriptReplacesPreviewWhenEnhancementStarts() {
        #expect(
            RecorderTranscriptPresentation.text(
                for: .enhancing,
                currentText: "实时预览",
                finalizedTranscript: "  最终原始转写  "
            ) == "最终原始转写"
        )
        #expect(
            RecorderTranscriptPresentation.text(
                for: .transcribing,
                currentText: "实时预览",
                finalizedTranscript: "最终原始转写"
            ) == "实时预览"
        )
        #expect(
            RecorderTranscriptPresentation.text(
                for: .enhancing,
                currentText: "实时预览",
                finalizedTranscript: "   "
            ) == "实时预览"
        )
    }

    @Test func windowPresentationChangesOnlyForStructuralState() {
        let empty = RecorderWindowPresentation.resolve(
            showLiveTranscript: true,
            recordingState: .recording,
            partialTranscript: "",
            assistantIsVisible: false,
            assistantIsBusy: false
        )
        let firstText = RecorderWindowPresentation.resolve(
            showLiveTranscript: true,
            recordingState: .recording,
            partialTranscript: "first",
            assistantIsVisible: false,
            assistantIsBusy: false
        )
        let moreText = RecorderWindowPresentation.resolve(
            showLiveTranscript: true,
            recordingState: .recording,
            partialTranscript: "first and more",
            assistantIsVisible: false,
            assistantIsBusy: false
        )

        #expect(empty != firstText)
        #expect(firstText == moreText)
        #expect(firstText.hasVisibleTranscript)
    }

    @MainActor
    @Test func presentationModelDoesNotRepublishForEachTranscriptToken() async throws {
        let provider = RecorderPresentationTestProvider()
        let model = RecorderWindowPresentationModel(
            stateProvider: provider,
            assistantSession: AssistantSession(),
            showLiveTranscript: true
        )
        var publicationCount = 0
        let cancellable = model.$value.dropFirst().sink { _ in publicationCount += 1 }

        provider.partialTranscript = "first"
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(publicationCount == 1)

        provider.partialTranscript = "first and more"
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(publicationCount == 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test func transitionPolicyDefersHeavyContentAndCapsScrollWork() {
        #expect(RecorderWindowTransitionPolicy.transcriptRevealDelayMilliseconds >= 100)
        #expect(RecorderWindowTransitionPolicy.transcriptRevealDelayMilliseconds < 300)
        #expect(RecorderWindowTransitionPolicy.transcriptFadeDuration <= 0.15)
        #expect(RecorderWindowTransitionPolicy.minimumScrollIntervalMilliseconds >= 50)
    }
}

@MainActor
private final class RecorderPresentationTestProvider: ObservableObject, RecorderStateProvider {
    @Published var recordingState: RecordingState = .recording
    @Published var partialTranscript = ""
}
