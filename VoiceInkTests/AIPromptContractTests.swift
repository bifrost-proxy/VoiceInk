import Testing
@testable import VoiceInk

struct AIPromptContractTests {
    @Test func enhancementSystemTemplateDefinesConservativeEditingBoundaries() {
        let template = AIPrompts.enhancementSystemTemplate

        #expect(template.contains("# Editing Boundaries"))
        #expect(template.contains("Make the minimum changes necessary"))
        #expect(template.contains("# Literal Token Preservation"))
        #expect(template.contains("Never replace one well-formed token with a different token"))
        #expect(template.contains("An unfamiliar token is not evidence of a transcription error."))
        #expect(template.contains("preserve the original token exactly"))
        #expect(template.contains("# Language Preservation"))
        #expect(template.contains("language as a property of each source span"))
        #expect(template.contains("For every sentence, clause, phrase, heading, list item, or other span"))
        #expect(template.contains("keep the corresponding output span in the same language"))
        #expect(template.contains("Do not use the first span, last span, majority language"))
        #expect(template.contains("must not translate, anglicize, localize, or otherwise change its language"))
        #expect(template.contains("A requested tone, format, audience, or writing style does not imply a change of language."))
        #expect(template.contains("Translate only the specific span that <TRANSCRIPT> itself explicitly and unambiguously asks to translate."))
        #expect(template.contains("every output span uses the same language as its corresponding span"))
        #expect(template.contains("# Repetitions and Self-Corrections"))
        #expect(template.contains("Preserve repetitions that express emphasis"))
        #expect(template.contains("# Context Usage"))
        #expect(template.contains("possible canonical spellings, not mandatory replacements"))
        #expect(template.contains("Semantic relatedness, product-family similarity"))
        #expect(template.contains("must not initiate or justify replacing a clear literal token"))
        #expect(template.contains("When context conflicts with <TRANSCRIPT>, preserve <TRANSCRIPT>."))
        #expect(template.contains("# Spoken Controls"))
        #expect(template.contains("only when they are clearly being used as dictation commands"))
        #expect(template.contains("# Mixed-Language Text"))
        #expect(template.contains("Do not translate individual words or phrases merely because they are in another language."))
        #expect(template.contains("Normalize capitalization only when it preserves the same letters and token identity."))
        #expect(!template.contains("Use <CUSTOM_VOCABULARY> as the spelling authority"))
        #expect(!template.contains("Format obvious lists"))
        #expect(!template.contains("# Examples"))
    }

    @Test func customVocabularyGuidanceTreatsTermsAsHintsWithoutOverridingLiteralTokens() {
        let guidance = AIPrompts.customVocabularyGuidance

        #expect(guidance.contains("possible canonical spellings, not mandatory replacements"))
        #expect(guidance.contains("strong local evidence"))
        #expect(guidance.contains("Never replace a clear, well-formed token"))
        #expect(guidance.contains("If uncertain, preserve <TRANSCRIPT> unchanged."))
        #expect(!guidance.contains("spelling authority"))
    }

    @Test func taskInstructionsRemainInsideTheEditingContract() throws {
        let prompt = CustomPrompt(
            title: "Test",
            promptText: "Keep the message conversational.",
            useSystemInstructions: true
        )
        let finalPrompt = prompt.finalPromptText

        let boundaries = try #require(finalPrompt.range(of: "# Editing Boundaries"))
        let languagePreservation = try #require(finalPrompt.range(of: "# Language Preservation"))
        let taskInstructions = try #require(finalPrompt.range(of: "# Task Instructions"))

        #expect(languagePreservation.lowerBound < boundaries.lowerBound)
        #expect(boundaries.lowerBound < taskInstructions.lowerBound)
        #expect(finalPrompt.contains("<TASK_INSTRUCTIONS>\nKeep the message conversational.\n</TASK_INSTRUCTIONS>"))
    }

    @Test func everySystemWrappedEnhancementPromptPreservesTranscriptLanguage() {
        for template in PromptTemplates.all where template.useSystemInstructions {
            let finalPrompt = template.toCustomPrompt().finalPromptText

            #expect(finalPrompt.contains("language as a property of each source span"))
            #expect(finalPrompt.contains("keep the corresponding output span in the same language"))
            #expect(finalPrompt.contains("Preserve the user's code-switching pattern"))
            #expect(finalPrompt.contains("Never infer a translation request from context or task instructions"))
        }
    }
}
