import Testing

@testable import VoiceInk

struct RecorderAnimationPerformanceTests {
    @Test func meterPolicyCapsVisualUpdatesNearThirtyFramesPerSecond() {
        #expect(AudioMeterRenderingPolicy.updateIntervalMilliseconds >= 33)
        #expect(AudioMeterRenderingPolicy.timerLeewayMilliseconds > 0)
    }

    @Test func meterPolicySkipsImperceptibleChanges() {
        let previous = AudioMeter(averagePower: 0.42, peakPower: 0.60)

        #expect(
            !AudioMeterRenderingPolicy.shouldPublish(
                previous: previous,
                next: AudioMeter(averagePower: 0.423, peakPower: 0.604)
            )
        )
        #expect(
            AudioMeterRenderingPolicy.shouldPublish(
                previous: previous,
                next: AudioMeter(averagePower: 0.46, peakPower: 0.66)
            )
        )
    }

    @Test func meterDeliveryCoalescesPendingFramesToTheNewestSample() throws {
        let buffer = AudioMeterDeliveryBuffer()
        let first = AudioMeter(averagePower: 0.1, peakPower: 0.2)
        var latest = first

        buffer.activate()
        #expect(buffer.submit(first))
        for index in 1...1_000 {
            latest = AudioMeter(
                averagePower: Double(index) / 1_000,
                peakPower: min(1, Double(index) / 900)
            )
            #expect(!buffer.submit(latest))
        }
        #expect(try #require(buffer.takeLatestValue()) == latest)
        #expect(buffer.submit(first))
    }

    @Test func meterDeliveryRejectsLateFramesAfterRecordingStops() {
        let buffer = AudioMeterDeliveryBuffer()
        let meter = AudioMeter(averagePower: 0.7, peakPower: 0.9)

        #expect(!buffer.submit(meter))
        buffer.activate()
        #expect(buffer.submit(meter))

        buffer.deactivate()

        #expect(buffer.takeLatestValue() == nil)
        #expect(!buffer.submit(meter))
    }

    @Test func visualizerUsesOneBoundedBarLayout() {
        let silent = AudioVisualizerLayout.barHeights(
            for: AudioMeter(averagePower: 0, peakPower: 0),
            isActive: false
        )
        let active = AudioVisualizerLayout.barHeights(
            for: AudioMeter(averagePower: 0.62, peakPower: 0.88),
            isActive: true
        )

        #expect(silent.count == AudioVisualizerLayout.barCount)
        #expect(silent.allSatisfy { $0 == AudioVisualizerLayout.minHeight })
        #expect(active.count == AudioVisualizerLayout.barCount)
        #expect(
            active.allSatisfy {
                $0 >= AudioVisualizerLayout.minHeight && $0 <= AudioVisualizerLayout.maxHeight
            }
        )
        #expect(Set(active).count > 1)
    }
}
