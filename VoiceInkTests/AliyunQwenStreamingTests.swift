import Foundation
import SwiftData
import Testing
@testable import VoiceInk

struct AliyunQwenStreamingTests {
    @Test func catalogExposesExactNativeStreamingModelAndLanguages() throws {
        let provider = try #require(CloudProviderRegistry.provider(for: .aliyunQwen))
        let model = try #require(provider.models.first)

        #expect(provider.providerKey == "Alibaba Cloud Qwen")
        #expect(provider.languageCodes == AliyunQwenSpeechProvider.supportedLanguageCodes)
        #expect(provider.includesAutoDetect)
        #expect(provider.isStreamingOnly)
        #expect(model.name == "qwen-audio-3.0-asr-flash-streaming")
        #expect(model.supportsStreaming)
        #expect(TranscriptionRealtimeSupport.isRequired(for: model))
        #expect(model.supportedLanguages["auto"] == "Auto-detect")
        #expect(model.supportedLanguages["zh"] != nil)
        #expect(model.supportedLanguages["sk"] != nil)
        #expect(model.supportedLanguages.count == 31)
    }

    @Test func runTaskMapsAllProviderSpecificRecognitionOptions() throws {
        let settings = AliyunQwenSpeechSettings(
            region: .beijing,
            apiHost: "",
            semanticPunctuationEnabled: false,
            maxSentenceSilenceMilliseconds: 900,
            multiThresholdModeEnabled: true,
            heartbeatEnabled: true,
            speechNoiseThresholdEnabled: true,
            speechNoiseThreshold: 0.3,
            useVoiceInkVocabulary: true,
            vocabularyWeight: 5,
            contextPrompt: "VoiceInk、通义千问、百炼"
        )
        let request = try AliyunQwenStreamingProtocol.makeRunTask(
            taskID: "2bf83b9a-baeb-4fda-8d9a-000000000000",
            model: AliyunQwenSpeechProvider.modelID,
            format: "pcm",
            sampleRate: 16_000,
            language: "ZH",
            customVocabulary: [" VoiceInk ", "通义千问", "VoiceInk", ""],
            settings: settings
        )
        let root = try jsonObject(request)
        let header = try #require(root["header"] as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])
        let parameters = try #require(payload["parameters"] as? [String: Any])
        let input = try #require(payload["input"] as? [String: Any])

        #expect(header["action"] as? String == "run-task")
        #expect(header["streaming"] as? String == "duplex")
        #expect(payload["task_group"] as? String == "audio")
        #expect(payload["task"] as? String == "asr")
        #expect(payload["function"] as? String == "recognition")
        #expect(payload["model"] as? String == AliyunQwenSpeechProvider.modelID)
        #expect(parameters["format"] as? String == "pcm")
        #expect(parameters["sample_rate"] as? Int == 16_000)
        #expect(parameters["language_hints"] as? [String] == ["zh"])
        #expect(parameters["semantic_punctuation_enabled"] as? Bool == false)
        #expect(parameters["max_sentence_silence"] as? Int == 900)
        #expect(parameters["multi_threshold_mode_enabled"] as? Bool == true)
        #expect(parameters["heartbeat"] as? Bool == true)
        #expect(parameters["speech_noise_threshold"] as? Double == 0.3)
        #expect(parameters["vocabulary"] as? [String: Int] == ["VoiceInk": 5, "通义千问": 5])

        let context = try #require(input["context"] as? [[String: Any]])
        let content = try #require(context.first?["content"] as? [[String: Any]])
        #expect(context.first?["role"] as? String == "user")
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "VoiceInk、通义千问、百炼")
    }

    @Test func automaticLanguageAndDisabledOptionalFeaturesAreOmitted() throws {
        let settings = AliyunQwenSpeechSettings(
            region: .beijing,
            apiHost: "",
            semanticPunctuationEnabled: true,
            maxSentenceSilenceMilliseconds: 1_300,
            multiThresholdModeEnabled: true,
            heartbeatEnabled: false,
            speechNoiseThresholdEnabled: false,
            speechNoiseThreshold: 0.8,
            useVoiceInkVocabulary: false,
            vocabularyWeight: 4,
            contextPrompt: ""
        )
        #expect(!settings.multiThresholdModeEnabled)

        let request = try AliyunQwenStreamingProtocol.makeRunTask(
            taskID: UUID().uuidString,
            model: AliyunQwenSpeechProvider.modelID,
            format: "pcm",
            sampleRate: 16_000,
            language: "auto",
            customVocabulary: ["VoiceInk"],
            settings: settings
        )
        let root = try jsonObject(request)
        let payload = try #require(root["payload"] as? [String: Any])
        let parameters = try #require(payload["parameters"] as? [String: Any])
        let input = try #require(payload["input"] as? [String: Any])

        #expect(parameters["language_hints"] == nil)
        #expect(parameters["vocabulary"] == nil)
        #expect(parameters["speech_noise_threshold"] == nil)
        #expect(parameters["semantic_punctuation_enabled"] as? Bool == true)
        #expect(parameters["multi_threshold_mode_enabled"] as? Bool == false)
        #expect(input.isEmpty)
    }

    @Test func finishTaskUsesTheOriginalTaskIdentifier() throws {
        let taskID = UUID().uuidString
        let root = try jsonObject(try AliyunQwenStreamingProtocol.makeFinishTask(taskID: taskID))
        let header = try #require(root["header"] as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])

        #expect(header["action"] as? String == "finish-task")
        #expect(header["task_id"] as? String == taskID)
        #expect(header["streaming"] as? String == "duplex")
        #expect((payload["input"] as? [String: Any])?.isEmpty == true)
    }

    @Test func serverEventsPreservePartialFinalHeartbeatAndFailureState() throws {
        #expect(try parse(event: "task-started", payload: [:]) == .taskStarted)
        #expect(try parse(event: "task-finished", payload: [:]) == .taskFinished)

        let partial = try parse(
            event: "result-generated",
            payload: [
                "output": [
                    "sentence": [
                        "sentence_id": 3,
                        "text": "实时识",
                        "sentence_end": false,
                    ]
                ]
            ]
        )
        #expect(partial == .result(.init(id: 3, text: "实时识", isFinal: false, isHeartbeat: false)))

        let heartbeat = try parse(
            event: "result-generated",
            payload: [
                "output": [
                    "sentence": [
                        "sentence_id": 0,
                        "text": "",
                        "sentence_end": true,
                        "heartbeat": true,
                    ]
                ]
            ]
        )
        #expect(heartbeat == .result(.init(id: 0, text: "", isFinal: true, isHeartbeat: true)))

        let failure = try parse(
            event: "task-failed",
            payload: [:],
            extraHeader: ["error_code": "CLIENT_ERROR", "error_message": "invalid api key"]
        )
        #expect(failure == .taskFailed(code: "CLIENT_ERROR", message: "invalid api key"))
    }

    @MainActor
    @Test func settingsClampRangesValidateRegionsAndProtectWorkspaceEndpoint() throws {
        let suiteName = "VoiceInkTests.AliyunQwenSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AliyunQwenSpeechSettings.current(in: defaults) == .defaults)
        defaults.set(100, forKey: AliyunQwenSpeechSettings.Keys.maxSentenceSilenceMilliseconds)
        defaults.set(99, forKey: AliyunQwenSpeechSettings.Keys.vocabularyWeight)
        defaults.set(4.2, forKey: AliyunQwenSpeechSettings.Keys.speechNoiseThreshold)
        let clamped = AliyunQwenSpeechSettings.current(in: defaults)
        #expect(clamped.maxSentenceSilenceMilliseconds == 200)
        #expect(clamped.vocabularyWeight == 5)
        #expect(clamped.speechNoiseThreshold == 1)

        #expect(try AliyunQwenSpeechSettings.defaults.webSocketURL().absoluteString ==
            "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        let dedicated = settings(region: .singapore, host: "workspace.ap-southeast-1.maas.aliyuncs.com")
        #expect(try dedicated.webSocketURL().absoluteString ==
            "wss://workspace.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/inference")
        #expect(throws: AliyunQwenSettingsError.apiHostRegionMismatch) {
            _ = try self.settings(region: .beijing, host: "dashscope-intl.aliyuncs.com").webSocketURL()
        }
        #expect(throws: AliyunQwenSettingsError.invalidAPIHost) {
            _ = try self.settings(region: .beijing, host: "wss://example.com").webSocketURL()
        }

        let syncedKeys = [
            AliyunQwenSpeechSettings.Keys.region,
            AliyunQwenSpeechSettings.Keys.semanticPunctuationEnabled,
            AliyunQwenSpeechSettings.Keys.maxSentenceSilenceMilliseconds,
            AliyunQwenSpeechSettings.Keys.multiThresholdModeEnabled,
            AliyunQwenSpeechSettings.Keys.heartbeatEnabled,
            AliyunQwenSpeechSettings.Keys.speechNoiseThresholdEnabled,
            AliyunQwenSpeechSettings.Keys.speechNoiseThreshold,
            AliyunQwenSpeechSettings.Keys.useVoiceInkVocabulary,
            AliyunQwenSpeechSettings.Keys.vocabularyWeight,
        ]
        #expect(syncedKeys.allSatisfy(CloudConfigurationSyncService.isEligiblePreferenceKey))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.apiHost))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.contextPrompt))
    }

    @Test func vocabularyBecomesAliyunHotwords() throws {
        let container = try ModelContainer(
            for: VocabularyWord.self,
            WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "VoiceInk"))
        context.insert(VocabularyWord(word: "通义千问"))
        context.insert(WordReplacement(originalText: "voice ink", replacementText: "VoiceInk App"))
        try context.save()

        let provider = AliyunQwenStreamingProvider(modelContext: context)
        #expect(Set(provider.customHotwordTerms()) == ["VoiceInk", "通义千问"])
        #expect(APIKeyManager.storagePolicy(forProvider: "Alibaba Cloud Qwen") == .keychainOnly)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func parse(
        event: String,
        payload: [String: Any],
        extraHeader: [String: Any] = [:]
    ) throws -> AliyunQwenServerEvent {
        var header: [String: Any] = ["event": event, "task_id": UUID().uuidString]
        header.merge(extraHeader) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["header": header, "payload": payload])
        return try AliyunQwenStreamingProtocol.parseServerMessage(.string(String(decoding: data, as: UTF8.self)))
    }

    private func settings(region: AliyunQwenRegion, host: String) -> AliyunQwenSpeechSettings {
        AliyunQwenSpeechSettings(
            region: region,
            apiHost: host,
            semanticPunctuationEnabled: false,
            maxSentenceSilenceMilliseconds: 1_300,
            multiThresholdModeEnabled: false,
            heartbeatEnabled: true,
            speechNoiseThresholdEnabled: false,
            speechNoiseThreshold: 0,
            useVoiceInkVocabulary: true,
            vocabularyWeight: 4,
            contextPrompt: ""
        )
    }
}
