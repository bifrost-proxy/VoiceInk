import AppKit
import Foundation
import Testing

@testable import VoiceInk

@MainActor
struct RecordingShortcutModeHandlerTests {
    @Test func replacementMonitorConsumesReleaseForASeededActivePress() {
        let monitor = ShortcutMonitor()
        let shortcut = Shortcut.key(keyCode: 12, modifierFlags: [.command])
        monitor.configureShortcutStates(
            [.primaryRecording: shortcut],
            initiallyPressedActions: [.primaryRecording: 5]
        )

        #expect(monitor.isTrackingPress(for: .primaryRecording))
        #expect(
            monitor.handleEvent(
                kind: .keyUp,
                keyCode: shortcut.keyCode,
                modifierFlags: [],
                eventTime: 5.2
            )
        )
        #expect(!monitor.isTrackingPress(for: .primaryRecording))
    }

    @Test func activeShortcutPressRemainsVisibleUntilKeyUp() async {
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { true },
            recordingState: { .recording },
            toggleRecorderPanel: { _ in },
            cancelRecording: {},
            cancelEnhancementAndPasteOriginal: {}
        )

        await handler.handleKeyDown(
            action: .primaryRecording,
            eventTime: 5,
            mode: .pushToTalk
        )
        #expect(handler.hasActivePress)

        await handler.handleKeyUp(
            action: .primaryRecording,
            eventTime: 5.2,
            mode: .pushToTalk
        )
        #expect(!handler.hasActivePress)
    }

    @Test func monitoringLossSynthesizesReleaseForAHeldPushToTalkPress() async {
        var recordingState: RecordingState = .recording
        var toggleCount = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { true },
            recordingState: { recordingState },
            toggleRecorderPanel: { _ in
                toggleCount += 1
                recordingState = .idle
            },
            cancelRecording: {},
            cancelEnhancementAndPasteOriginal: {}
        )

        await handler.handleKeyDown(
            action: .primaryRecording,
            eventTime: 5,
            mode: .pushToTalk
        )
        await handler.handleMonitoringLoss(eventTime: 6)

        #expect(!handler.hasActivePress)
        #expect(toggleCount == 1)
        #expect(recordingState == .idle)
    }

    @Test func monitoringLossPreservesHandsFreeToggleState() async throws {
        var recordingState: RecordingState = .idle
        var toggleCount = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { recordingState != .idle },
            recordingState: { recordingState },
            toggleRecorderPanel: { _ in
                toggleCount += 1
                recordingState = recordingState == .idle ? .recording : .idle
            },
            cancelRecording: {},
            cancelEnhancementAndPasteOriginal: {}
        )

        await handler.handleKeyDown(action: .primaryRecording, eventTime: 5, mode: .toggle)
        await handler.handleKeyUp(action: .primaryRecording, eventTime: 5.1, mode: .toggle)
        #expect(recordingState == .recording)

        await handler.handleMonitoringLoss(eventTime: 6)
        try await Task.sleep(for: .milliseconds(510))
        await handler.handleKeyDown(action: .primaryRecording, eventTime: 7, mode: .toggle)

        #expect(toggleCount == 2)
        #expect(recordingState == .idle)
    }

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

    @Test func pushToTalkReleaseStopsStartupBeforePanelIsVisible() async {
        var recordingState: RecordingState = .idle
        var toggleCount = 0

        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { false },
            recordingState: { recordingState },
            toggleRecorderPanel: { _ in
                toggleCount += 1
                recordingState = toggleCount == 1 ? .starting : .idle
            },
            cancelRecording: {},
            cancelEnhancementAndPasteOriginal: {}
        )

        await handler.handleKeyDown(
            action: .primaryRecording,
            eventTime: 20,
            mode: .pushToTalk
        )
        await handler.handleKeyUp(
            action: .primaryRecording,
            eventTime: 20.1,
            mode: .pushToTalk
        )

        #expect(toggleCount == 2)
        #expect(recordingState == .idle)
    }

    @Test func longHybridReleaseStopsStartupBeforePanelIsVisible() async {
        var recordingState: RecordingState = .idle
        var toggleCount = 0

        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { false },
            recordingState: { recordingState },
            toggleRecorderPanel: { _ in
                toggleCount += 1
                recordingState = toggleCount == 1 ? .starting : .idle
            },
            cancelRecording: {},
            cancelEnhancementAndPasteOriginal: {}
        )

        await handler.handleKeyDown(
            action: .primaryRecording,
            eventTime: 30,
            mode: .hybrid
        )
        await handler.handleKeyUp(
            action: .primaryRecording,
            eventTime: 30.6,
            mode: .hybrid
        )

        #expect(toggleCount == 2)
        #expect(recordingState == .idle)
    }
}
