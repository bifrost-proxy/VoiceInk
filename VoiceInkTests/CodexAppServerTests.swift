import Foundation
import Testing

@testable import VoiceInk

struct CodexAppServerTests {
    @Test func parsesVisibleModelsAndTheirSupportedEfforts() throws {
        let response = Data(
            #"{"id":2,"result":{"data":[{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"GPT-5.6 Luna","description":"Fast","isDefault":false,"hidden":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"medium","description":"Balanced"}]},{"id":"hidden","model":"hidden","displayName":"Hidden","description":"","isDefault":false,"hidden":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":[]}]}}"#
                .utf8
        )

        let models = try CodexAppServerProtocol.parseModelListResponse(response)

        #expect(models.count == 1)
        #expect(models.first?.model == "gpt-5.6-luna")
        #expect(models.first?.supportedReasoningEfforts == ["low", "medium"])
    }

    @Test func recommendsEfficientAvailableModelWithoutAssumingCatalogContents() throws {
        let defaultModel = CodexModelOption(
            id: "gpt-heavy",
            model: "gpt-heavy",
            displayName: "Heavy",
            description: "",
            isDefault: true,
            defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["high"]
        )
        let miniModel = CodexModelOption(
            id: "account-mini",
            model: "account-mini",
            displayName: "Account Mini",
            description: "",
            isDefault: false,
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: ["low", "medium"]
        )

        let selected = try #require(
            CodexAppServerProtocol.recommendedModel(in: [defaultModel, miniModel]))
        #expect(selected.id == miniModel.id)
        #expect(CodexAppServerProtocol.resolvedEffort("ultra", for: selected) == "low")
    }

    @MainActor
    @Test func codexPreferencesArePortableICloudConfiguration() {
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey(LocalCLIService.executionModeKey))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey(LocalCLIService.codexModelKey))
        #expect(
            CloudConfigurationSyncService.isEligiblePreferenceKey(LocalCLIService.codexReasoningEffortKey)
        )
        #expect(
            CloudConfigurationSyncService.isEligiblePreferenceKey(LocalCLIService.timeoutSecondsKey))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICEINK_RUN_CODEX_INTEGRATION"] == "1"))
    func liveAppServerReusesOneProcessAcrossIsolatedEnhancements() async throws {
        let service = CodexAppServerService()
        defer { service.shutdown() }
        let models = try await service.listModels()
        let model = try #require(CodexAppServerProtocol.recommendedModel(in: models))
        let effort = CodexAppServerProtocol.resolvedEffort("low", for: model)
        let systemPrompt =
            "Polish the text without changing its language. Return only the polished text."

        let first = try await service.enhance(
            systemPrompt: systemPrompt,
            userPrompt: "今天 我们 开会 讨论 项目进度",
            model: model.model,
            effort: effort,
            timeout: 45
        )
        let second = try await service.enhance(
            systemPrompt: systemPrompt,
            userPrompt: "明天 我们 准时 上线",
            model: model.model,
            effort: effort,
            timeout: 45
        )

        #expect(!first.isEmpty)
        #expect(!second.isEmpty)
        #expect(service.processLaunchCount == 1)
    }
}
