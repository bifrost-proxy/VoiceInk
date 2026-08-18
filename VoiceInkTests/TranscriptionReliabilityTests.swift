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
                transportSendFailures: 0,
                hasTerminalReceiveError: false,
                drainedInTime: drainedInTime
            )
        )
    }

    @Test func completeStreamingAudioKeepsStreamingResult() {
        #expect(
            !StreamingAudioIntegrityPolicy.requiresBatchFallback(
                droppedChunks: 0,
                transportSendFailures: 0,
                hasTerminalReceiveError: false,
                drainedInTime: true
            )
        )
    }

    @Test(arguments: [
        (transportSendFailures: 1, hasTerminalReceiveError: false),
        (transportSendFailures: 0, hasTerminalReceiveError: true),
    ])
    func transportFailuresAlwaysRequireBatchFallback(
        transportSendFailures: Int,
        hasTerminalReceiveError: Bool
    ) {
        #expect(
            StreamingAudioIntegrityPolicy.requiresBatchFallback(
                droppedChunks: 0,
                transportSendFailures: transportSendFailures,
                hasTerminalReceiveError: hasTerminalReceiveError,
                drainedInTime: true
            )
        )
    }

    @Test func stalledStreamingWorkStopsBlockingAtTheDeadline() async {
        let stalled = Task.detached {
            _ = try? await Task.sleep(for: .seconds(5))
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

    @Test func audioFileWritesAreBatchedAtTheConfiguredDuration() {
        #expect(AudioFileWriteBatchingPolicy.targetBatchByteCount == 8_000)

        var batcher = AudioFileWriteBatcher(targetBatchByteCount: 8)
        let firstChunk = Data([0, 1, 2, 3])
        let firstBatch = firstChunk.withUnsafeBytes { batcher.append($0) }
        #expect(firstBatch == nil)
        #expect(batcher.bufferedByteCount == 4)

        let secondChunk = Data([4, 5, 6, 7])
        let batch = secondChunk.withUnsafeBytes { batcher.append($0) }
        #expect(batch == Data([0, 1, 2, 3, 4, 5, 6, 7]))
        #expect(batcher.bufferedByteCount == 0)
    }

    @Test func audioFileWriteBatcherFlushesTheRemainingTail() {
        var batcher = AudioFileWriteBatcher(targetBatchByteCount: 8)
        #expect(batcher.append(Data([0, 1, 2, 3])) == nil)

        #expect(batcher.flush() == Data([0, 1, 2, 3]))
        #expect(batcher.bufferedByteCount == 0)
        #expect(batcher.flush() == nil)
    }

    @Test func recentOrphanAudioIsProtectedFromCleanup() {
        let now = Date()
        let url = URL(fileURLWithPath: "/tmp/current-recording.wav")

        #expect(
            !OrphanAudioCleanupPolicy.shouldDelete(
                fileURL: url,
                contentModificationDate: now.addingTimeInterval(-60),
                now: now
            )
        )
    }

    @Test func staleOrphanWAVIsEligibleForCleanup() {
        let now = Date()
        let url = URL(fileURLWithPath: "/tmp/stale-recording.wav")

        #expect(
            OrphanAudioCleanupPolicy.shouldDelete(
                fileURL: url,
                contentModificationDate: now.addingTimeInterval(
                    -OrphanAudioCleanupPolicy.minimumFileAge - 1
                ),
                now: now
            )
        )
        #expect(
            !OrphanAudioCleanupPolicy.shouldDelete(
                fileURL: URL(fileURLWithPath: "/tmp/stale-recording.download"),
                contentModificationDate: .distantPast,
                now: now
            )
        )
    }

    @Test func modelPrewarmSkipsActiveRecordingsAndCloudProviders() {
        #expect(
            ModelPrewarmPolicy.shouldRun(
                isEnabled: true,
                isRecordingActive: false,
                provider: .qwenMlx
            )
        )
        #expect(
            !ModelPrewarmPolicy.shouldRun(
                isEnabled: true,
                isRecordingActive: true,
                provider: .qwenMlx
            )
        )
        #expect(
            !ModelPrewarmPolicy.shouldRun(
                isEnabled: true,
                isRecordingActive: false,
                provider: .doubaoSpeech
            )
        )
    }

    @Test func qwenAudioBatcherCoalescesChunksAndFlushesTail() {
        var batcher = QwenMLXAudioBatcher(targetByteCount: 8)

        #expect(batcher.append(Data([0, 1, 2])).isEmpty)
        #expect(batcher.append(Data([3, 4, 5])).isEmpty)
        #expect(
            batcher.append(Data([6, 7, 8, 9, 10, 11, 12, 13, 14, 15]))
                == [Data([0, 1, 2, 3, 4, 5, 6, 7]), Data([8, 9, 10, 11, 12, 13, 14, 15])]
        )
        #expect(batcher.bufferedByteCount == 0)

        #expect(batcher.append(Data([16, 17, 18])).isEmpty)
        #expect(batcher.flush() == Data([16, 17, 18]))
        #expect(batcher.flush() == nil)
    }
}
