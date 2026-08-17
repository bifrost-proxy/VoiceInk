import Foundation
import SwiftData
import Testing
@testable import VoiceInk

struct DoubaoStreamingTests {
    @Test func cloudProviderCatalogPinsVolcengineAndDoubaoFirst() {
        let view = CloudProviderManagementView(selectedProviderID: nil) { _ in }

        #expect(Array(view.providerDescriptors.prefix(2).map(\.displayName)) == [
            "Volcengine Ark",
            "Doubao Speech",
        ])
    }

    @Test func fullClientRequestUsesDocumentedPCMFormatWithoutCompression() throws {
        let frame = try DoubaoStreamingProtocol.makeFullClientRequest(
            customVocabulary: ["VoiceInk", "豆包"]
        )
        let bytes = [UInt8](frame)

        #expect(Array(bytes.prefix(4)) == [0x11, 0x10, 0x10, 0x00])
        let payloadSize = Int(readUInt32(bytes, offset: 4))
        #expect(payloadSize == bytes.count - 8)

        let payload = Data(bytes[8...])
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let audio = try #require(root["audio"] as? [String: Any])
        let request = try #require(root["request"] as? [String: Any])
        let user = try #require(root["user"] as? [String: Any])

        #expect(audio["format"] as? String == "pcm")
        #expect(audio["codec"] as? String == "raw")
        #expect(audio["rate"] as? Int == 16_000)
        #expect(audio["bits"] as? Int == 16)
        #expect(audio["channel"] as? Int == 1)
        #expect(request["model_name"] as? String == "bigmodel")
        #expect(request["enable_nonstream"] as? Bool == true)
        #expect(request["enable_itn"] as? Bool == true)
        #expect(request["enable_punc"] as? Bool == true)
        #expect(request["enable_ddc"] as? Bool == false)
        #expect(request["enable_accelerate_text"] as? Bool == false)
        #expect(request["accelerate_score"] == nil)
        #expect(request["show_utterances"] as? Bool == true)
        #expect(request["end_window_size"] as? Int == 800)
        #expect((user["uid"] as? String)?.hasPrefix("voiceink-") == true)
        #expect(user["did"] == nil)

        let corpus = try #require(request["corpus"] as? [String: Any])
        let contextString = try #require(corpus["context"] as? String)
        let context = try #require(
            JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any]
        )
        let hotwords = try #require(context["hotwords"] as? [[String: String]])
        #expect(hotwords.compactMap { $0["word"] } == ["VoiceInk", "豆包"])
    }

    @Test func configurableRecognitionOptionsMapToOfficialRequestFields() throws {
        let settings = DoubaoSpeechSettings(
            enableTwoPassRecognition: false,
            enableTextNormalization: false,
            enablePunctuation: false,
            enableSemanticSmoothing: true,
            enableFirstTextAcceleration: true,
            firstTextAccelerationLevel: 12,
            silenceFinalizationMilliseconds: 1_200
        )
        let frame = try DoubaoStreamingProtocol.makeFullClientRequest(settings: settings)
        let bytes = [UInt8](frame)
        let payload = Data(bytes[8...])
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let request = try #require(root["request"] as? [String: Any])

        #expect(request["enable_nonstream"] as? Bool == false)
        #expect(request["enable_itn"] as? Bool == false)
        #expect(request["enable_punc"] as? Bool == false)
        #expect(request["enable_ddc"] as? Bool == true)
        #expect(request["enable_accelerate_text"] as? Bool == true)
        #expect(request["accelerate_score"] as? Int == 12)
        #expect(request["end_window_size"] as? Int == 1_200)
        #expect(request["show_utterances"] as? Bool == true)
        #expect(request["result_type"] as? String == "full")
    }

    @MainActor
    @Test func doubaoSettingsUseSafeDefaultsClampRangesAndRemainICloudEligible() throws {
        let suiteName = "VoiceInkTests.DoubaoSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(DoubaoSpeechSettings.current(in: defaults) == .defaults)

        defaults.set(99, forKey: DoubaoSpeechSettings.Keys.firstTextAccelerationLevel)
        defaults.set(100, forKey: DoubaoSpeechSettings.Keys.silenceFinalizationMilliseconds)
        let clamped = DoubaoSpeechSettings.current(in: defaults)
        #expect(clamped.firstTextAccelerationLevel == 20)
        #expect(clamped.silenceFinalizationMilliseconds == 300)

        let keys = [
            DoubaoSpeechSettings.Keys.enableTwoPassRecognition,
            DoubaoSpeechSettings.Keys.enableTextNormalization,
            DoubaoSpeechSettings.Keys.enablePunctuation,
            DoubaoSpeechSettings.Keys.enableSemanticSmoothing,
            DoubaoSpeechSettings.Keys.enableFirstTextAcceleration,
            DoubaoSpeechSettings.Keys.firstTextAccelerationLevel,
            DoubaoSpeechSettings.Keys.silenceFinalizationMilliseconds,
        ]
        #expect(keys.allSatisfy(CloudConfigurationSyncService.isEligiblePreferenceKey))
    }

    @Test func vocabularyAndProperNounsBecomeDoubaoHotwordsButReplacementsDoNot() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: VocabularyWord.self,
            WordReplacement.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "VoiceInk"))
        context.insert(VocabularyWord(word: "豆包语音", kind: .properNoun))
        context.insert(VocabularyWord(word: "另一个专有词", kind: .properNoun))
        context.insert(WordReplacement(originalText: "voice ink", replacementText: "VoiceInk App"))
        try context.save()

        let provider = DoubaoStreamingProvider(modelContext: context)
        let reusableContext = TranscriptionVocabularyContext.entries(from: context)

        #expect(Set(provider.customHotwordTerms()) == ["VoiceInk", "另一个专有词", "豆包语音"])
        #expect(Dictionary(uniqueKeysWithValues: reusableContext.map { ($0.term, $0) }) == [
            "VoiceInk": TranscriptionVocabularyContextEntry(
                term: "VoiceInk", kind: .vocabulary),
            "另一个专有词": TranscriptionVocabularyContextEntry(
                term: "另一个专有词", kind: .properNoun),
            "豆包语音": TranscriptionVocabularyContextEntry(
                term: "豆包语音",
                kind: .properNoun
            ),
        ])
    }

    @Test func audioFramesMarkOnlyTheCommitAsFinal() {
        let audio = Data([0x01, 0x02, 0x03])
        let regular = [UInt8](DoubaoStreamingProtocol.makeAudioRequest(audio, isFinal: false))
        let final = [UInt8](DoubaoStreamingProtocol.makeAudioRequest(Data(), isFinal: true))

        #expect(Array(regular.prefix(4)) == [0x11, 0x20, 0x00, 0x00])
        #expect(readUInt32(regular, offset: 4) == 3)
        #expect(Array(regular.dropFirst(8)) == [0x01, 0x02, 0x03])
        #expect(Array(final.prefix(4)) == [0x11, 0x22, 0x00, 0x00])
        #expect(readUInt32(final, offset: 4) == 0)
    }

    @Test func finalServerFrameReturnsFullAndStableText() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": [
                "text": "你好，VoiceInk。",
                "utterances": [
                    ["text": "你好，", "definite": true],
                    ["text": "VoiceInk。", "definite": false],
                ],
            ]
        ])
        var frame = Data([0x11, 0x93, 0x10, 0x00])
        appendUInt32(3, to: &frame)
        appendUInt32(UInt32(payload.count), to: &frame)
        frame.append(payload)

        let parsedResponse = try DoubaoStreamingProtocol.parseServerFrame(frame)
        let response = try #require(parsedResponse)
        #expect(response.text == "你好，VoiceInk。")
        #expect(response.stableText == "你好，")
        #expect(response.isFinal)
    }

    @Test func serverErrorFramePreservesCodeAndMessage() throws {
        let message = Data("invalid api key".utf8)
        var frame = Data([0x11, 0xF0, 0x10, 0x00])
        appendUInt32(45_000_003, to: &frame)
        appendUInt32(UInt32(message.count), to: &frame)
        frame.append(message)

        #expect(throws: DoubaoStreamingProtocolError.server(code: 45_000_003, message: "invalid api key")) {
            _ = try DoubaoStreamingProtocol.parseServerFrame(frame)
        }
    }

    @Test func allProviderKeysAlwaysUseSystemKeychain() {
        #expect(APIKeyManager.storagePolicy(forProvider: "Doubao Speech") == .keychainOnly)
        #expect(APIKeyManager.storagePolicy(forProvider: "doubao speech") == .keychainOnly)
        #expect(APIKeyManager.storagePolicy(forProvider: "Volcengine Ark") == .keychainOnly)
        #expect(APIKeyManager.storagePolicy(forProvider: "Deepgram") == .keychainOnly)
    }

    #if LOCAL_BUILD
        @Test func keychainOnlyStorageRoundTripsInAdHocBuild() {
            let testKey = "doubaoSpeechKeychainTest-\(UUID().uuidString)"
            defer {
                _ = KeychainService.shared.delete(
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                )
            }

            #expect(
                KeychainService.shared.save(
                    "temporary-test-value",
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                )
            )
            #expect(
                KeychainService.shared.getString(
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                ) == "temporary-test-value"
            )
            #expect(
                KeychainService.shared.exists(
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                )
            )
        }

        @Test func legacyLocalCredentialMigratesIntoKeychain() {
            let testKey = "legacyKeychainMigrationTest-\(UUID().uuidString)"
            let legacyDefaultsKey = "LocalKeychain_\(testKey)"
            let legacyData = Data("temporary-migration-value".utf8)
            UserDefaults.standard.set(legacyData, forKey: legacyDefaultsKey)
            defer {
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                _ = KeychainService.shared.delete(
                    forKey: testKey,
                    syncable: false,
                    storagePolicy: .keychainOnly
                )
            }

            #expect(
                KeychainService.shared.getString(
                    forKey: testKey,
                    syncable: false,
                    storagePolicy: .keychainOnly
                ) == "temporary-migration-value"
            )
            #expect(UserDefaults.standard.data(forKey: legacyDefaultsKey) == nil)
        }
    #endif

    @Test func catalogExposesBothDoubaoTwoPointZeroBillingResources() throws {
        let provider = try #require(CloudProviderRegistry.provider(for: .doubaoSpeech))
        let models = provider.models

        #expect(models.map(\.name) == [
            "volc.seedasr.sauc.duration",
            "volc.seedasr.sauc.concurrent",
        ])
        #expect(models.map(\.supportsStreaming) == [true, true])
        let defaultModel = try #require(models.first)
        #expect(TranscriptionRealtimeSupport.isRequired(for: defaultModel))
    }

    @MainActor
    @Test func newOnboardingDefaultsToDoubaoSpeechAndVolcengineArk() throws {
        let suiteName = "VoiceInkTests.DoubaoArkOnboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh-Hans-CN"],
            supportsQwenMLX: true
        )

        #expect(coordinator.transcriptionSetupKind == .cloud)
        #expect(coordinator.selectedOnboardingTranscriptionProvider?.providerKey == "Doubao Speech")
        #expect(coordinator.selectedOnboardingTranscriptionModel?.name == DoubaoSpeechProvider.defaultResourceID)
        #expect(coordinator.selectedOnboardingTranscriptionModel?.displayName == "Doubao Streaming ASR 2.0")
        #expect(coordinator.selectedOnboardingProvider == .ark)
    }

    @MainActor
    @Test func onboardingPreservesExistingProviderSelections() throws {
        let suiteName = "VoiceInkTests.ExistingOnboardingProviders.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            OnboardingTranscriptionSetupKind.local.rawValue,
            forKey: OnboardingStorageKeys.transcriptionSetupKind
        )
        defaults.set("Deepgram", forKey: OnboardingStorageKeys.transcriptionProvider)
        defaults.set(AIProvider.gemini.rawValue, forKey: OnboardingStorageKeys.aiProvider)

        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["en-US"],
            supportsQwenMLX: true
        )

        #expect(coordinator.transcriptionSetupKind == .local)
        #expect(coordinator.selectedOnboardingTranscriptionProvider?.providerKey == "Deepgram")
        #expect(coordinator.selectedOnboardingProvider == .gemini)
    }

    private func readUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
