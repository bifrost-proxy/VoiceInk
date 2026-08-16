import Testing
@testable import VoiceInk

struct AIPromptContractTests {
    @Test func enhancementSystemTemplateDefinesConservativeEditingBoundaries() {
        let template = AIPrompts.enhancementSystemTemplate

        #expect(template.contains("# Editing Boundaries"))
        #expect(template.contains("Make the minimum changes necessary"))
        #expect(template.contains("# Output Language"))
        #expect(template.contains("Determine the output language from <TRANSCRIPT>"))
        #expect(template.contains("Chinese input must remain Chinese"))
        #expect(template.contains("Never translate the whole transcript, convert it to English"))
        #expect(template.contains("A requested tone, format, audience, or writing style does not imply a change of language."))
        #expect(template.contains("Only translate when <TRANSCRIPT> itself explicitly and unambiguously asks for translation."))
        #expect(template.contains("# Repetitions and Self-Corrections"))
        #expect(template.contains("Preserve repetitions that express emphasis"))
        #expect(template.contains("# Context Usage"))
        #expect(template.contains("When context conflicts with <TRANSCRIPT>, preserve <TRANSCRIPT>."))
        #expect(template.contains("# Spoken Controls"))
        #expect(template.contains("only when they are clearly being used as dictation commands"))
        #expect(template.contains("# Mixed-Language Text"))
        #expect(template.contains("Do not translate individual words or phrases merely because they are in another language."))
        #expect(!template.contains("Format obvious lists"))
        #expect(!template.contains("# Examples"))
    }

    @Test func taskInstructionsRemainInsideTheEditingContract() throws {
        let prompt = CustomPrompt(
            title: "Test",
            promptText: "Keep the message conversational.",
            useSystemInstructions: true
        )
        let finalPrompt = prompt.finalPromptText

        let boundaries = try #require(finalPrompt.range(of: "# Editing Boundaries"))
        let outputLanguage = try #require(finalPrompt.range(of: "# Output Language"))
        let taskInstructions = try #require(finalPrompt.range(of: "# Task Instructions"))

        #expect(outputLanguage.lowerBound < boundaries.lowerBound)
        #expect(boundaries.lowerBound < taskInstructions.lowerBound)
        #expect(finalPrompt.contains("<TASK_INSTRUCTIONS>\nKeep the message conversational.\n</TASK_INSTRUCTIONS>"))
    }

    @Test func everySystemWrappedEnhancementPromptPreservesTranscriptLanguage() {
        for template in PromptTemplates.all where template.useSystemInstructions {
            let finalPrompt = template.toCustomPrompt().finalPromptText

            #expect(finalPrompt.contains("Determine the output language from <TRANSCRIPT>"))
            #expect(finalPrompt.contains("Chinese input must remain Chinese"))
            #expect(finalPrompt.contains("Preserve the user's original language switching"))
            #expect(finalPrompt.contains("Language found only in context or task instructions is not a translation request."))
        }
    }
}
