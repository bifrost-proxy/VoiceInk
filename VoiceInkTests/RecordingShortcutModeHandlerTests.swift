import Foundation
import Testing

@testable import VoiceInk

@MainActor
struct RecordingShortcutModeHandlerTests {
    @Test func enhancementShortcutBypassesPolishWithoutStartingAnotherRecording() async {
        var recordingState: RecordingState = .enhancing
        var toggleCount = 0
        var cancelCount = 0
        var bypassCount = 0

        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { false },
            isRecorderVisible: { true },
            recordingState: { recordingState },
            toggleRecorderPanel: { _ in toggleCount += 1 },
            cancelRecording: { cancelCount += 1 },
            cancelEnhancementAndPasteOriginal: {
                bypassCount += 1
                recordingState = .busy
            }
        )

        await handler.handleKeyDown(
            action: .primaryRecording,
            eventTime: 10,
            mode: .toggle
        )
        await handler.handleKeyUp(
            action: .primaryRecording,
            eventTime: 10.1,
            mode: .toggle
        )

        #expect(bypassCount == 1)
        #expect(toggleCount == 0)
        #expect(cancelCount == 0)
    }
}
