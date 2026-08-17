import Foundation
import Testing

@testable import VoiceInk

struct TranscriptionReliabilityTests {
    @Test func captureRingKeepsHeadroomForShortCPUSpikes() {
        #expect(AudioCaptureBufferingPolicy.inputRingSlotCount >= 256)
    }

    @Test(arguments: [
        (droppedChunks: 1, drainedInTime: true),
        (droppedChunks: 0, drainedInTime: false),
        (droppedChunks: 5, drainedInTime: false),
    ])
    func incompleteStreamingAudioRequiresBatchFallback(
        droppedChunks: Int,
        drainedInTime: Bool
    ) {
        #expect(
            StreamingAudioIntegrityPolicy.requiresBatchFallback(
                droppedChunks: droppedChunks,
                drainedInTime: drainedInTime
            )
        )
    }

    @Test func completeStreamingAudioKeepsStreamingResult() {
        #expect(
            !StreamingAudioIntegrityPolicy.requiresBatchFallback(
                droppedChunks: 0,
                drainedInTime: true
            )
        )
    }

    @Test func stalledStreamingWorkStopsBlockingAtTheDeadline() async {
        let stalled = Task.detached {
            try? await Task.sleep(for: .seconds(5))
        }
        let startedAt = ContinuousClock.now

        let completed = await StreamingAudioIntegrityPolicy.waitForCompletion(
            of: stalled,
            timeout: .milliseconds(25)
        )

        #expect(!completed)
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        #expect(stalled.isCancelled)
    }

    @Test func completedStreamingWorkDoesNotWaitForTheDeadline() async {
        let completedTask = Task.detached {}

        let completed = await StreamingAudioIntegrityPolicy.waitForCompletion(
            of: completedTask,
            timeout: .seconds(5)
        )

        #expect(completed)
        #expect(!completedTask.isCancelled)
    }
}
