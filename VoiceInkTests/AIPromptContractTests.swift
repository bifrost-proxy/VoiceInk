import Testing
@testable import VoiceInk

struct AIPromptContractTests {
    @Test func enhancementSystemTemplateDefinesConservativeEditingBoundaries() {
        let template = AIPrompts.enhancementSystemTemplate

        #expect(template.contains("# Editing Boundaries"))
        #expect(template.contains("Make the minimum changes necessary"))
        #expect(template.contains("# Repetitions and Self-Corrections"))
        #expect(template.contains("Preserve repetitions that express emphasis"))
        #expect(template.contains("# Context Usage"))
        #expect(template.contains("When context conflicts with <TRANSCRIPT>, preserve <TRANSCRIPT>."))
        #expect(template.contains("# Spoken Controls"))
        #expect(template.contains("only when they are clearly being used as dictation commands"))
        #expect(template.contains("# Mixed-Language Text"))
        #expect(template.contains("Do not translate words merely because they are in another language."))
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
        let taskInstructions = try #require(finalPrompt.range(of: "# Task Instructions"))

        #expect(boundaries.lowerBound < taskInstructions.lowerBound)
        #expect(finalPrompt.contains("<TASK_INSTRUCTIONS>\nKeep the message conversational.\n</TASK_INSTRUCTIONS>"))
    }
}
