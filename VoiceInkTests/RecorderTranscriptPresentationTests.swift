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
}
