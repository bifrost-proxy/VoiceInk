import Foundation
import SwiftData
import Testing
@testable import VoiceInk

private let aliyunQwenIntegrationDirectory = URL(
    fileURLWithPath: "/tmp/voiceink-aliyun-qwen-integration",
    isDirectory: true
)
private let aliyunQwenIntegrationAPIKeyURL = aliyunQwenIntegrationDirectory.appendingPathComponent("api-key.pipe")
private let aliyunQwenIntegrationAPIHostURL = aliyunQwenIntegrationDirectory.appendingPathComponent("api-host.pipe")
private let aliyunQwenIntegrationAudioPathURL = aliyunQwenIntegrationDirectory.appendingPathComponent(
    "audio-path.pipe"
)

struct AliyunQwenStreamingTests {
    @Test func providerSettingsHaveCompleteChineseLocalizations() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = projectRoot
            .appendingPathComponent("VoiceInk", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])
        let keys = [
            "Connection",
            "Service region",
            "The API key and endpoint must belong to the same region.",
            "China (Beijing)",
            "International (Singapore)",
            "API host",
            "For a dedicated voice-input key, paste API Host from the same key page. Host, OpenAI-compatible, and DashScope URLs are accepted.",
            "The API host stays on this Mac and does not sync through iCloud.",
            "Enter a valid Alibaba Cloud Model Studio API host using HTTPS or WSS.",
            "The API host does not match the selected Alibaba Cloud region.",
            "Recognition Options",
            "Semantic sentence segmentation",
            "Uses semantic boundaries for higher accuracy, with greater final-result latency.",
            "VAD silence threshold",
            "Multi-threshold VAD",
            "Prevents VAD from producing excessively long sentences.",
            "Keep silent sessions alive",
            "Keeps the server connection active while VoiceInk sends silent audio.",
            "Use VoiceInk vocabulary",
            "Sends vocabulary as per-session inline hotwords.",
            "Hotword weight",
            "Higher values make the model more likely to recognize configured terms (1–5).",
            "Custom noise threshold",
            "Fine-tunes VAD sensitivity for unusually noisy or quiet environments.",
            "Speech/noise threshold",
            "Lower values retain more sound; higher values filter more aggressively (-1.0–1.0).",
            "Recognition context",
            "Add domain terms or prior context to improve recognition (up to 400 characters).",
            "Optional context",
            "Allow selected-text features",
            "Requires the active mode's Selected Text setting. Full selected text is not sent to speech recognition.",
            "Allow clipboard features",
            "Requires the active mode's Clipboard setting. Full clipboard text is not sent to speech recognition.",
            "Allow application name",
            "Requires the active mode's Active Application setting. The bundle identifier stays local.",
            "Allow window title",
            "Requires the active mode's Window Title setting. Window titles may contain sensitive names.",
            "Recognition options sync through iCloud; recognition context stays on this Mac.",
        ]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "Missing key: \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations: \(key)"
            )
            let localization = try #require(
                localizations["zh-Hans"] as? [String: Any],
                "Missing zh-Hans localization: \(key)"
            )
            let stringUnit = try #require(
                localization["stringUnit"] as? [String: Any],
                "Missing zh-Hans string unit: \(key)"
            )
            #expect(stringUnit["state"] as? String == "translated")
            let value = try #require(stringUnit["value"] as? String)
            #expect(!value.isEmpty)
            #expect(value != key)
        }
    }

    @Test(
        .enabled(if: FileManager.default.fileExists(atPath: aliyunQwenIntegrationAPIKeyURL.path))
    )
    func dedicatedWorkspaceCredentialConnectsToConfiguredHost() async throws {
        let apiKey = try readIntegrationPipe(aliyunQwenIntegrationAPIKeyURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiHost = try readIntegrationPipe(aliyunQwenIntegrationAPIHostURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!apiKey.isEmpty)
        #expect(!apiHost.isEmpty)
        let settings = settings(region: .beijing, host: apiHost)

        try await AliyunQwenWebSocketSession.verify(
            apiKey: apiKey,
            model: AliyunQwenSpeechProvider.modelID,
            settings: settings
        )
    }

    @Test func successfulTaskStartDoesNotCloseTheConnectionWhenItsTimeoutIsCancelled() async throws {
        let connection = AliyunQwenLifecycleTestConnection()
        let connector = AliyunQwenLifecycleTestConnector(connection: connection)
        let pool = CloudSpeechConnectionPool(connector: connector)
        let session = AliyunQwenWebSocketSession(
            eventsContinuation: nil,
            connectionPool: pool,
            connector: connector
        )

        try await session.connect(
            apiKey: "test-key",
            model: AliyunQwenSpeechProvider.modelID,
            language: "zh",
            customVocabulary: [],
            settings: settings(region: .beijing, host: "test.cn-beijing.maas.aliyuncs.com"),
            format: "pcm"
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(!connection.isClosed)
        await session.disconnect()
        #expect(connection.isClosed)
        await pool.shutdown()
    }

    @Test func taskFinishedCompletesCommitWithoutWaitingForTimeout() async throws {
        let connection = AliyunQwenFinishTestConnection()
        let connector = AliyunQwenFinishTestConnector(connection: connection)
        let pool = CloudSpeechConnectionPool(connector: connector)
        let session = AliyunQwenWebSocketSession(
            eventsContinuation: nil,
            connectionPool: pool,
            connector: connector
        )
        defer { Task { await pool.shutdown() } }

        try await session.connect(
            apiKey: "test-key",
            model: AliyunQwenSpeechProvider.modelID,
            language: "zh",
            customVocabulary: [],
            settings: settings(region: .beijing, host: "test.cn-beijing.maas.aliyuncs.com"),
            format: "pcm"
        )
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await session.commit()
        }
        #expect(elapsed < .seconds(1))
        await session.disconnect()
    }

    @Test func failedFullChunkSendRemainsPendingUntilAConfirmedRetry() async throws {
        let connection = AliyunQwenSendFailureTestConnection(failingBinarySends: 1)
        let connector = AliyunQwenSendFailureTestConnector(connection: connection)
        let pool = CloudSpeechConnectionPool(connector: connector)
        let session = AliyunQwenWebSocketSession(
            eventsContinuation: nil,
            connectionPool: pool,
            connector: connector
        )
        defer { Task { await pool.shutdown() } }

        try await session.connect(
            apiKey: "test-key",
            model: AliyunQwenSpeechProvider.modelID,
            language: "zh",
            customVocabulary: [],
            settings: settings(region: .beijing, host: "test.cn-beijing.maas.aliyuncs.com"),
            format: "pcm"
        )

        let chunk = Data(repeating: 0x5a, count: 3_200)
        do {
            try await session.sendAudioChunk(chunk)
            Issue.record("The injected binary send should fail")
        } catch {}
        #expect(await session.pendingAudioByteCount == 3_200)

        try await session.sendAudioChunk(Data())
        #expect(await session.pendingAudioByteCount == 0)
        #expect(connection.successfulBinaryPayloads == [chunk])
        await session.disconnect()
    }

    @Test func failedRemainderSendIsNotClearedBeforeCommitRetry() async throws {
        let connection = AliyunQwenSendFailureTestConnection(failingBinarySends: 1)
        let connector = AliyunQwenSendFailureTestConnector(connection: connection)
        let pool = CloudSpeechConnectionPool(connector: connector)
        let session = AliyunQwenWebSocketSession(
            eventsContinuation: nil,
            connectionPool: pool,
            connector: connector
        )
        defer { Task { await pool.shutdown() } }

        try await session.connect(
            apiKey: "test-key",
            model: AliyunQwenSpeechProvider.modelID,
            language: "zh",
            customVocabulary: [],
            settings: settings(region: .beijing, host: "test.cn-beijing.maas.aliyuncs.com"),
            format: "pcm"
        )
        try await session.sendAudioChunk(Data(repeating: 0x11, count: 900))

        do {
            try await session.commit()
            Issue.record("The injected remainder send should fail")
        } catch {}
        #expect(await session.pendingAudioByteCount == 900)
        await session.disconnect()
    }

    @Test func fastOfflineFallbackUsesBase64HTTPAndParsesFinalText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AliyunQwenOfflineURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let transcriber = AliyunQwenOfflineTranscriber(urlSession: urlSession)
        AliyunQwenOfflineURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            #expect(request.value(forHTTPHeaderField: "X-DashScope-SSE") == "disable")
            #expect(request.url?.path == "/api/v1/services/aigc/multimodal-generation/generation")

            let bodyData = try requestBodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(body["model"] as? String == AliyunQwenOfflineTranscriber.modelID)
            let input = try #require(body["input"] as? [String: Any])
            let messages = try #require(input["messages"] as? [[String: Any]])
            let audioContent = try #require(messages.last?["content"] as? [[String: Any]])
            let inputAudio = try #require(audioContent.first?["input_audio"] as? [String: Any])
            #expect((inputAudio["data"] as? String)?.hasPrefix("data:audio/wav;base64,") == true)

            let response = try #require(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = try JSONSerialization.data(withJSONObject: ["output": ["text": "快速恢复成功"]])
            return (response, data)
        }
        defer { AliyunQwenOfflineURLProtocol.handler = nil }

        let text = try await transcriber.transcribe(
            audioData: Data([0x52, 0x49, 0x46, 0x46]),
            apiKey: "secret",
            language: "zh",
            customVocabulary: ["VoiceInk"],
            settings: settings(region: .beijing, host: "workspace.cn-beijing.maas.aliyuncs.com")
        )
        #expect(text == "快速恢复成功")
    }

    @Test func oversizedOfflineRequestIsRejectedBeforeBase64Allocation() {
        let transcriber = AliyunQwenOfflineTranscriber()
        #expect(!transcriber.supportsFastRequest(audioData: Data(count: 7_200_000)))
    }

    @Test func runTaskCarriesPrivacyFilteredDynamicContext() throws {
        let envelope = RecognitionContextEnvelope(
            capturedAt: Date(),
            applicationName: nil,
            windowTitle: nil,
            configuredScenario: nil,
            features: [
                ContextFeature(value: "VoiceInk", sources: [.selectedText], priority: 90),
                ContextFeature(value: "Bifrost", sources: [.selectedText], priority: 90),
            ]
        )
        let request = try AliyunQwenStreamingProtocol.makeRunTask(
            taskID: "task-1",
            model: AliyunQwenSpeechProvider.modelID,
            format: "pcm",
            sampleRate: 16_000,
            language: "zh",
            customVocabulary: [],
            settings: settings(region: .beijing, host: ""),
            recognitionContext: envelope
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        )
        let header = try #require(root["header"] as? [String: Any])
        #expect(header["action"] as? String == "run-task")
        let payload = try #require(root["payload"] as? [String: Any])
        let input = try #require(payload["input"] as? [String: Any])
        let context = try #require(input["context"] as? [[String: Any]])
        let content = try #require(context.first?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "[选中文本关键词] VoiceInk, Bifrost")
    }

    @Test func dynamicContextRequiresBothModeAndProviderOptIn() throws {
        let mode = ModeConfig(
            name: "Test",
            isAIEnhancementEnabled: false,
            useClipboardContext: true,
            useSelectedTextContext: true,
            useScreenCapture: true
        )
        let snapshot = RecordingContextSnapshot(
            selectedText: "VoiceInk uses Bifrost",
            clipboardText: "PrivateClipboardTerm",
            screenOCRText: "PrivateScreenTerm"
        )
        let settings = AliyunQwenSpeechSettings(
            region: .beijing,
            apiHost: "",
            semanticPunctuationEnabled: false,
            maxSentenceSilenceMilliseconds: 1_300,
            multiThresholdModeEnabled: false,
            heartbeatEnabled: true,
            speechNoiseThresholdEnabled: false,
            speechNoiseThreshold: 0,
            useVoiceInkVocabulary: true,
            vocabularyWeight: 4,
            contextPrompt: "",
            useSelectedTextContext: true,
            useClipboardContext: false
        )

        let envelope = try #require(
            SpeechRecognitionContextBuilder.build(
                snapshot: snapshot,
                mode: mode,
                providerConfiguration: RecognitionContextProviderConfiguration(
                    permissions: settings.recognitionContextPermissions,
                    configuredScenario: nil
                )
            )
        )
        let context = try #require(QwenRecognitionContextSerializer.serialize(envelope).value)
        #expect(context.contains("VoiceInk"))
        #expect(context.contains("Bifrost"))
        #expect(!context.contains("PrivateClipboardTerm"))
        #expect(!context.contains("PrivateScreenTerm"))
        #expect(context.count <= AliyunQwenSpeechSettings.maximumContextLength)
    }

    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: aliyunQwenIntegrationAPIKeyURL.path)
                && FileManager.default.fileExists(atPath: aliyunQwenIntegrationAudioPathURL.path)
        )
    )
    func dedicatedWorkspaceCredentialTranscribesRealAudio() async throws {
        let apiKey = try readIntegrationPipe(aliyunQwenIntegrationAPIKeyURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiHost = try readIntegrationPipe(aliyunQwenIntegrationAPIHostURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let audioPath = try readIntegrationPipe(aliyunQwenIntegrationAudioPathURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let session = AliyunQwenWebSocketSession(eventsContinuation: nil)

        do {
            try await session.connect(
                apiKey: apiKey,
                model: AliyunQwenSpeechProvider.modelID,
                language: "zh",
                customVocabulary: [],
                settings: settings(region: .beijing, host: apiHost),
                format: "wav"
            )
            for offset in stride(from: 0, to: audioData.count, by: 3_200) {
                let end = min(offset + 3_200, audioData.count)
                try await session.sendAudioChunk(audioData.subdata(in: offset..<end))
                try await Task.sleep(for: .milliseconds(100))
            }
            try await session.commit()
            let transcript = await session.finalTranscript()
            await session.disconnect()
            #expect(!transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            await session.disconnect()
            throw error
        }
    }

    private func readIntegrationPipe(_ url: URL) throws -> String {
        let handle = try #require(FileHandle(forReadingAtPath: url.path))
        defer { try? handle.close() }
        let data = try #require(try handle.readToEnd())
        return String(decoding: data, as: UTF8.self)
    }

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
        #expect(content.first?["text"] as? String == "[场景] VoiceInk、通义千问、百炼")
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
        defaults.set(true, forKey: AliyunQwenSpeechSettings.Keys.keepConnectionReady)
        defaults.set(
            "https://user-workspace.cn-beijing.maas.aliyuncs.com/api/v1",
            forKey: AliyunQwenSpeechSettings.Keys.apiHost
        )
        let clamped = AliyunQwenSpeechSettings.current(in: defaults)
        #expect(clamped.maxSentenceSilenceMilliseconds == 200)
        #expect(clamped.vocabularyWeight == 5)
        #expect(clamped.speechNoiseThreshold == 1)
        #expect(clamped.keepConnectionReady)
        #expect(try clamped.webSocketURL().absoluteString ==
            "wss://user-workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference")

        #expect(try AliyunQwenSpeechSettings.defaults.webSocketURL().absoluteString ==
            "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        let dedicated = settings(region: .singapore, host: "workspace.ap-southeast-1.maas.aliyuncs.com")
        #expect(try dedicated.webSocketURL().absoluteString ==
            "wss://workspace.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/inference")
        let beijingHost = "ws-example.cn-beijing.maas.aliyuncs.com"
        for value in [
            beijingHost,
            "https://\(beijingHost)/compatible-mode/v1",
            "https://\(beijingHost)/api/v1",
            "wss://\(beijingHost)/api-ws/v1/inference",
        ] {
            #expect(try settings(region: .beijing, host: value).webSocketURL().absoluteString ==
                "wss://\(beijingHost)/api-ws/v1/inference")
        }
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
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.useSelectedTextContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.useClipboardContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.useApplicationContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.useWindowTitleContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.legacyUseScreenContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(AliyunQwenSpeechSettings.Keys.keepConnectionReady))
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

        let provider = AliyunQwenStreamingProvider(
            customVocabulary: TranscriptionVocabularyContext.uniqueTerms(from: context)
        )
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

private final class AliyunQwenOfflineURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try Self.handler.unwrap()
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw AliyunQwenOfflineError.invalidResponse }
        return self
    }
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try request.httpBodyStream.unwrap()
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? AliyunQwenOfflineError.invalidResponse }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private struct AliyunQwenLifecycleTestConnector: CloudSpeechWebSocketConnecting {
    let connection: AliyunQwenLifecycleTestConnection

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        connection
    }
}

private struct AliyunQwenSendFailureTestConnector: CloudSpeechWebSocketConnecting {
    let connection: AliyunQwenSendFailureTestConnection

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        connection
    }
}

private struct AliyunQwenFinishTestConnector: CloudSpeechWebSocketConnecting {
    let connection: AliyunQwenFinishTestConnection

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        connection
    }
}

private final class AliyunQwenFinishTestConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveCount = 0
    private var finishSent = false

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message,
            let data = text.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let header = root["header"] as? [String: Any],
            header["action"] as? String == "finish-task"
        else { return }
        lock.withLock { finishSent = true }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let current = lock.withLock {
            receiveCount += 1
            return receiveCount
        }
        if current == 1 {
            return try event("task-started")
        }
        while !lock.withLock({ finishSent }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try event("task-finished")
    }

    private func event(_ name: String) throws -> URLSessionWebSocketTask.Message {
        let data = try JSONSerialization.data(withJSONObject: [
            "header": ["event": name, "task_id": "task-1"],
            "payload": [:] as [String: Any],
        ])
        return .string(String(decoding: data, as: UTF8.self))
    }

    func ping(timeout _: Duration) async throws {}
    func close() {}
}

private final class AliyunQwenSendFailureTestConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private enum InjectedError: Error { case sendFailed }

    private let lock = NSLock()
    private var receiveCount = 0
    private var remainingFailingBinarySends: Int
    private var storedSuccessfulBinaryPayloads: [Data] = []

    init(failingBinarySends: Int) {
        remainingFailingBinarySends = failingBinarySends
    }

    var successfulBinaryPayloads: [Data] {
        lock.withLock { storedSuccessfulBinaryPayloads }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .data(let data) = message else { return }
        let shouldFail = lock.withLock {
            if remainingFailingBinarySends > 0 {
                remainingFailingBinarySends -= 1
                return true
            }
            storedSuccessfulBinaryPayloads.append(data)
            return false
        }
        if shouldFail { throw InjectedError.sendFailed }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let currentReceiveCount = lock.withLock {
            receiveCount += 1
            return receiveCount
        }
        if currentReceiveCount == 1 {
            let payload: [String: Any] = [
                "header": ["event": "task-started", "task_id": UUID().uuidString],
                "payload": [:] as [String: Any],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return .string(String(decoding: data, as: UTF8.self))
        }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func ping(timeout _: Duration) async throws {}
    func close() {}
}

private final class AliyunQwenLifecycleTestConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveCount = 0
    private var storedIsClosed = false

    var isClosed: Bool {
        lock.withLock { storedIsClosed }
    }

    func send(_: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let currentReceiveCount = lock.withLock {
            receiveCount += 1
            return receiveCount
        }
        if currentReceiveCount == 1 {
            let payload: [String: Any] = [
                "header": [
                    "event": "task-started",
                    "task_id": UUID().uuidString,
                ],
                "payload": [:] as [String: Any],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return .string(String(decoding: data, as: UTF8.self))
        }

        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func ping(timeout _: Duration) async throws {}

    func close() {
        lock.withLock {
            storedIsClosed = true
        }
    }
}
