import Testing
@testable import VoiceInk

struct ModeConnectionRequirementTests {
    @Test func detectsMissingDoubaoKeyForSynchronizedMode() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "volc.seedasr.sauc.duration" }
        )

        #expect(
            ModeConnectionRequirements.transcriptionIssue(for: model, hasAPIKey: { _ in false })
                == .missingAPIKey(providerKey: "Doubao Speech")
        )
        #expect(ModeConnectionRequirements.transcriptionIssue(for: model, hasAPIKey: { _ in true }) == nil)
    }

    @Test func detectsMissingArkKeyWithoutFallingBackToAnotherProvider() {
        let mode = ModeConfig(
            name: "Cloud mode",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: "volc.seedasr.sauc.duration",
            selectedAIProvider: AIProvider.ark.rawValue,
            selectedAIModel: "ep-example"
        )

        #expect(
            ModeConnectionRequirements.enhancementIssue(for: mode, hasAPIKey: { _ in false })
                == .missingAPIKey(providerKey: AIProvider.ark.rawValue)
        )
        #expect(ModeConnectionRequirements.enhancementIssue(for: mode, hasAPIKey: { _ in true }) == nil)
    }

    @Test func detectsIncompleteArkModelConfiguration() {
        let mode = ModeConfig(
            name: "Cloud mode",
            isAIEnhancementEnabled: true,
            selectedAIProvider: AIProvider.ark.rawValue,
            selectedAIModel: ""
        )

        #expect(
            ModeConnectionRequirements.enhancementIssue(for: mode, hasAPIKey: { _ in true })
                == .incompleteConfiguration(providerKey: AIProvider.ark.rawValue)
        )
    }

    @Test func providerConfigurationNavigationCanResolveBothPreferredProviders() {
        let providerKeys = CloudProviderManagementView.providerDescriptors.map(\.providerKey)

        #expect(providerKeys.prefix(2) == [AIProvider.ark.rawValue, "Doubao Speech"])
    }
}
