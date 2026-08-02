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
}
