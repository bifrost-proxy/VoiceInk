import AVFoundation
import Foundation
import Testing

@testable import VoiceInk

struct AudioCaptureReliabilityTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func statefulResamplerDoesNotAccumulateCallbackRoundingDrift(inputSampleRate: Double) throws {
        let callbackFrameSizes = [128, 256, 480, 512, 1_024]
        let durationSeconds = 60
        let expectedOutputFrames = 16_000 * durationSeconds

        for callbackFrameSize in callbackFrameSizes {
            let resampler = try StatefulAudioResampler(
                inputSampleRate: inputSampleRate,
                maximumInputFrames: AVAudioFrameCount(callbackFrameSize)
            )
            let inputFrameCount = Int(inputSampleRate) * durationSeconds
            var consumedInputFrames = 0
            var outputFrames = 0

            while consumedInputFrames < inputFrameCount {
                let frames = min(callbackFrameSize, inputFrameCount - consumedInputFrames)
                var samples = [Float32](repeating: 0, count: frames)
                for frame in 0..<frames {
                    let sampleIndex = consumedInputFrames + frame
                    samples[frame] = sin(Float32(sampleIndex) * 0.01)
                }
                let converted = try samples.withUnsafeBufferPointer { buffer in
                    try resampler.convert(
                        interleavedSamples: buffer.baseAddress!,
                        frameCount: UInt32(frames),
                        channelCount: 1
                    )
                }
                outputFrames += converted.count / MemoryLayout<Int16>.size
                consumedInputFrames += frames
            }

            outputFrames += try resampler.finish().count / MemoryLayout<Int16>.size
            #expect(
                abs(outputFrames - expectedOutputFrames) <= 64,
                "\(inputSampleRate) Hz / \(callbackFrameSize)-frame callbacks produced \(outputFrames), expected \(expectedOutputFrames)"
            )
        }
    }

    @Test func captureIntegrityIsPersistedIntoPerformanceMetrics() {
        let integrity = AudioCaptureIntegritySnapshot(
            droppedBackpressureBuffers: 2,
            droppedCapacityBuffers: 3,
            droppedFrames: 1_024,
            inputFrames: 48_000,
            outputFrames: 16_000,
            inputSampleRate: 48_000
        )
        var performance = TranscriptionPerformanceSnapshot(executionMode: "streaming")

        performance.recordCaptureIntegrity(integrity)

        #expect(performance.captureDroppedBuffers == 5)
        #expect(performance.captureDroppedFrames == 1_024)
        #expect(performance.captureInputFrames == 48_000)
        #expect(performance.captureOutputFrames == 16_000)
        #expect(performance.captureInputSampleRate == 48_000)
    }

    @Test func transcriptionRequiresAtLeastOneConvertedAudioFrame() {
        #expect(!AudioCaptureIntegritySnapshot.empty.hasAudioForTranscription)
        #expect(
            !AudioCaptureIntegritySnapshot(
                inputFrames: 1,
                outputFrames: 0,
                inputSampleRate: 48_000
            ).hasAudioForTranscription
        )
        #expect(
            AudioCaptureIntegritySnapshot(
                inputFrames: 3,
                outputFrames: 1,
                inputSampleRate: 48_000
            ).hasAudioForTranscription
        )
    }
}
