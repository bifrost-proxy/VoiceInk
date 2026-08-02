import Testing
@testable import VoiceInk

struct IncrementalTranscriptAssemblerTests {
    @Test func liveTranscriptKeepsFinalizedWindowsVisible() {
        var assembler = IncrementalTranscriptAssembler()

        #expect(assembler.updatePartial("第一段内容") == "第一段内容")
        #expect(assembler.finalize("第一段内容") == "第一段内容")
        #expect(assembler.updatePartial("第二段内容") == "第一段内容第二段内容")
        #expect(assembler.finalize("第二段内容") == "第一段内容第二段内容")
    }

    @Test func overlappingWindowsAreMergedWithoutRepeatingText() {
        var assembler = IncrementalTranscriptAssembler()

        #expect(assembler.finalize("效果如何你能懂感觉实时") == "效果如何你能懂感觉实时")
        #expect(
            assembler.updatePartial("实时性有点差就是每次说完话")
                == "效果如何你能懂感觉实时性有点差就是每次说完话"
        )
        #expect(
            assembler.finalize("实时性有点差就是每次说完话")
                == "效果如何你能懂感觉实时性有点差就是每次说完话"
        )
        #expect(
            IncrementalTranscriptAssembler.merge("看一下不太对劲刚", "刚我搞了几次")
                == "看一下不太对劲刚我搞了几次"
        )
    }

    @Test func shorterDecodeDoesNotEraseTheLatestHypothesis() {
        var assembler = IncrementalTranscriptAssembler()

        _ = assembler.updatePartial("这是一个完整的实时结果")
        #expect(assembler.updatePartial("这是一个完整的") == "这是一个完整的实时结果")
        #expect(assembler.finalize("") == "这是一个完整的实时结果")
    }

    @Test func englishWindowsKeepNaturalSpacing() {
        #expect(
            IncrementalTranscriptAssembler.merge("Hello world.", "This is VoiceInk")
                == "Hello world. This is VoiceInk"
        )
        #expect(
            IncrementalTranscriptAssembler.merge("Hello realtime world", "realtime world again")
                == "Hello realtime world again"
        )
    }

    @Test func pauseDetectionRequiresTheWholeProbeWindowToBeQuiet() {
        #expect(
            BufferedOnDeviceStreamingProvider.isTrailingSilence(
                in: [Float](repeating: 0.001, count: 9_600),
                probeSamples: 9_600,
                rmsLimit: 0.0018
            )
        )
        #expect(
            !BufferedOnDeviceStreamingProvider.isTrailingSilence(
                in: [Float](repeating: 0.003, count: 9_600),
                probeSamples: 9_600,
                rmsLimit: 0.0018
            )
        )
        #expect(
            !BufferedOnDeviceStreamingProvider.isTrailingSilence(
                in: [Float](repeating: 0, count: 9_599),
                probeSamples: 9_600,
                rmsLimit: 0.0018
            )
        )
    }

    @Test func pauseBoundaryIsFoundAfterSpeechResumes() {
        let speech = [Float](repeating: 0.02, count: 24_000)
        let pause = [Float](repeating: 0.0005, count: 11_000)
        let resumedSpeech = [Float](repeating: 0.02, count: 4_000)

        let boundary = BufferedOnDeviceStreamingProvider.pauseBoundary(
            in: speech + pause + resumedSpeech,
            minimumSegmentSamples: 24_000,
            probeSamples: 9_600,
            rmsLimit: 0.0018
        )

        #expect(boundary != nil)
        #expect(boundary! >= 33_600)
        #expect(boundary! <= 35_100)
    }

    @Test func leadingSilenceDoesNotCreateAnEmptyPhrase() {
        let leadingSilence = [Float](repeating: 0.0005, count: 30_000)
        let speech = [Float](repeating: 0.02, count: 10_000)

        #expect(
            BufferedOnDeviceStreamingProvider.pauseBoundary(
                in: leadingSilence + speech,
                minimumSegmentSamples: 24_000,
                probeSamples: 9_600,
                rmsLimit: 0.0018
            ) == nil
        )
    }
}
