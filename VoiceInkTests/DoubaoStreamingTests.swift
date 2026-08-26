import Foundation
import Security
import SwiftData
import Testing
@testable import VoiceInk

private final class APIKeyKeychainStoreStub: APIKeyKeychainStore {
    let readStarted = DispatchSemaphore(value: 0)
    let allowReadToFinish = DispatchSemaphore(value: 0)
    var blocksReads = false
    var readResult: KeychainDataReadResult = .notFound

    private let lock = NSLock()
    private var _readKeys: [String] = []
    private var _savedKeys: [String] = []

    var readKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _readKeys
    }

    var savedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _savedKeys
    }

    func save(
        data: Data,
        forKey key: String,
        syncable: Bool,
        storagePolicy: KeychainStoragePolicy
    ) -> Bool {
        lock.lock()
        _savedKeys.append(key)
        lock.unlock()
        return true
    }

    func readData(
        forKey key: String,
        syncable: Bool,
        storagePolicy: KeychainStoragePolicy,
        allowAuthenticationUI: Bool
    ) -> KeychainDataReadResult {
        lock.lock()
        _readKeys.append(key)
        lock.unlock()
        readStarted.signal()
        if blocksReads {
            allowReadToFinish.wait()
        }
        return readResult
    }

    func getString(
        forKey key: String,
        syncable: Bool,
        storagePolicy: KeychainStoragePolicy,
        allowAuthenticationUI: Bool
    ) -> String? {
        switch readData(
            forKey: key,
            syncable: syncable,
            storagePolicy: storagePolicy,
            allowAuthenticationUI: allowAuthenticationUI
        ) {
        case .value(let data):
            return String(data: data, encoding: .utf8)
        case .notFound, .unavailable:
            return nil
        }
    }

    func delete(
        forKey key: String,
        syncable: Bool,
        storagePolicy: KeychainStoragePolicy
    ) -> Bool {
        true
    }
}

struct DoubaoStreamingTests {
    @Test func poiCityInputExplainsSingleCityLimitInChinese() throws {
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
        let key = "Optional. Enter one prefecture-level city only, such as Shenzhen."
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let localization = try #require(localizations["zh-Hans"] as? [String: Any])
        let stringUnit = try #require(localization["stringUnit"] as? [String: Any])

        #expect(stringUnit["state"] as? String == "translated")
        #expect(stringUnit["value"] as? String == "可选填；每次仅支持一个地级市，例如深圳市。")
    }

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
        #expect(request["enable_poi_fc"] == nil)
        #expect(request["enable_music_fc"] == nil)
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
            silenceFinalizationMilliseconds: 1_200,
            enablePOIFunctionCall: true,
            poiCityName: " 北京市 ",
            enableMusicFunctionCall: true
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
        // Domain function calls require two-pass recognition, so invalid
        // combinations stay persisted but are not sent to the service.
        #expect(request["enable_poi_fc"] == nil)
        #expect(request["enable_music_fc"] == nil)
        #expect(request["corpus"] == nil)
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
        defaults.set("  上海市  ", forKey: DoubaoSpeechSettings.Keys.poiCityName)
        defaults.set(true, forKey: DoubaoSpeechSettings.Keys.keepConnectionReady)
        let clamped = DoubaoSpeechSettings.current(in: defaults)
        #expect(clamped.firstTextAccelerationLevel == 20)
        #expect(clamped.silenceFinalizationMilliseconds == 300)
        #expect(clamped.poiCityName == "上海市")
        #expect(clamped.keepConnectionReady)

        let keys = [
            DoubaoSpeechSettings.Keys.enableTwoPassRecognition,
            DoubaoSpeechSettings.Keys.enableTextNormalization,
            DoubaoSpeechSettings.Keys.enablePunctuation,
            DoubaoSpeechSettings.Keys.enableSemanticSmoothing,
            DoubaoSpeechSettings.Keys.enableFirstTextAcceleration,
            DoubaoSpeechSettings.Keys.firstTextAccelerationLevel,
            DoubaoSpeechSettings.Keys.silenceFinalizationMilliseconds,
            DoubaoSpeechSettings.Keys.enablePOIFunctionCall,
            DoubaoSpeechSettings.Keys.enableMusicFunctionCall,
        ]
        #expect(keys.allSatisfy(CloudConfigurationSyncService.isEligiblePreferenceKey))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.poiCityName))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.contextPrompt))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.useSelectedTextContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.useClipboardContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.useApplicationContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.useWindowTitleContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.legacyUseScreenContext))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.keepConnectionReady))
    }

    @Test func domainFunctionCallsMergePOICityWithVocabularyContext() throws {
        let settings = DoubaoSpeechSettings(
            enableTwoPassRecognition: true,
            enableTextNormalization: true,
            enablePunctuation: true,
            enableSemanticSmoothing: false,
            enableFirstTextAcceleration: false,
            firstTextAccelerationLevel: 0,
            silenceFinalizationMilliseconds: 800,
            enablePOIFunctionCall: true,
            poiCityName: "北京市",
            enableMusicFunctionCall: true
        )
        let frame = try DoubaoStreamingProtocol.makeFullClientRequest(
            customVocabulary: ["VoiceInk", "五道口"],
            settings: settings
        )
        let payload = Data([UInt8](frame)[8...])
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let request = try #require(root["request"] as? [String: Any])

        #expect(request["enable_poi_fc"] as? Bool == true)
        #expect(request["enable_music_fc"] as? Bool == true)
        let corpus = try #require(request["corpus"] as? [String: Any])
        let contextString = try #require(corpus["context"] as? String)
        let context = try #require(
            JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any]
        )
        let hotwords = try #require(context["hotwords"] as? [[String: String]])
        #expect(hotwords.compactMap { $0["word"] } == ["VoiceInk", "五道口"])
        let location = try #require(context["loc_info"] as? [String: String])
        #expect(location["city_name"] == "北京市")
    }

    @Test func hotwordsLocationAndDialogContextShareTheSerializedCorpusContext() throws {
        let settings = DoubaoSpeechSettings(
            enableTwoPassRecognition: true,
            enableTextNormalization: true,
            enablePunctuation: true,
            enableSemanticSmoothing: false,
            enableFirstTextAcceleration: false,
            firstTextAccelerationLevel: 0,
            silenceFinalizationMilliseconds: 800,
            enablePOIFunctionCall: true,
            poiCityName: "深圳市"
        )
        let envelope = RecognitionContextEnvelope(
            capturedAt: Date(),
            applicationName: "Xcode",
            windowTitle: "VoiceInk",
            configuredScenario: nil,
            features: [
                ContextFeature(value: "RecognitionContext", sources: [.selectedText], priority: 90)
            ]
        )
        let frame = try DoubaoStreamingProtocol.makeFullClientRequest(
            customVocabulary: ["VoiceInk"],
            settings: settings,
            recognitionContext: envelope
        )
        let payload = Data([UInt8](frame)[8...])
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let request = try #require(root["request"] as? [String: Any])
        let corpus = try #require(request["corpus"] as? [String: Any])
        let contextString = try #require(corpus["context"] as? String)
        let context = try #require(
            JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any]
        )

        #expect(context["hotwords"] as? [[String: String]] == [["word": "VoiceInk"]])
        #expect(context["loc_info"] as? [String: String] == ["city_name": "深圳市"])
        #expect(context["context_type"] as? String == "dialog_ctx")
        let items = try #require(context["context_data"] as? [[String: String]])
        #expect(items.first?["text"] == "用户当前选中文本关键词：RecognitionContext")
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["VOICEINK_DOUBAO_CONTEXT_INTEGRATION"] == "1")
    )
    func realServiceAcceptsHotwordsLocationAndDialogContextTogether() async throws {
        let injectedAPIKey = ProcessInfo.processInfo.environment["VOICEINK_DOUBAO_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = try #require(
            injectedAPIKey?.isEmpty == false ? injectedAPIKey : nil,
            "Set VOICEINK_DOUBAO_API_KEY when opting into the live Doubao integration test."
        )
        let settings = DoubaoSpeechSettings(
            enableTwoPassRecognition: true,
            enableTextNormalization: true,
            enablePunctuation: true,
            enableSemanticSmoothing: false,
            enableFirstTextAcceleration: false,
            firstTextAccelerationLevel: 0,
            silenceFinalizationMilliseconds: 800,
            enablePOIFunctionCall: true,
            poiCityName: "深圳市"
        )
        let envelope = RecognitionContextEnvelope(
            capturedAt: Date(),
            applicationName: "VoiceInk",
            windowTitle: "Context integration",
            configuredScenario: "VoiceInk context verification",
            features: [
                ContextFeature(value: "RecognitionContext", sources: [.selectedText], priority: 90)
            ]
        )

        try await DoubaoWebSocketSession.verifyContextCombination(
            apiKey: apiKey,
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: ["VoiceInk"],
            settings: settings,
            recognitionContext: envelope
        )
    }

    @Test func vocabularyBecomesDoubaoHotwordsButReplacementsDoNot() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: VocabularyWord.self,
            WordReplacement.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "VoiceInk"))
        context.insert(VocabularyWord(word: "豆包语音"))
        context.insert(VocabularyWord(word: "另一个词汇"))
        context.insert(WordReplacement(originalText: "voice ink", replacementText: "VoiceInk App"))
        try context.save()

        let reusableContext = TranscriptionVocabularyContext.entries(from: context)
        let provider = DoubaoStreamingProvider(customVocabulary: reusableContext.map(\.term))

        #expect(Set(provider.customHotwordTerms()) == ["VoiceInk", "另一个词汇", "豆包语音"])
        #expect(Dictionary(uniqueKeysWithValues: reusableContext.map { ($0.term, $0) }) == [
            "VoiceInk": TranscriptionVocabularyContextEntry(term: "VoiceInk"),
            "另一个词汇": TranscriptionVocabularyContextEntry(term: "另一个词汇"),
            "豆包语音": TranscriptionVocabularyContextEntry(term: "豆包语音"),
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

    @Test func audioPacketizerEmitsFastFirstPacketThenDocumentedTwoHundredMillisecondPackets() {
        var packetizer = DoubaoAudioPacketizer()
        let callbackBytes = 340

        var packets: [Data] = []
        for value in 0..<38 {
            packets.append(contentsOf: packetizer.append(Data(repeating: UInt8(value), count: callbackBytes)))
        }

        #expect(DoubaoAudioPacketizer.firstPacketByteCount == 3_200)
        #expect(DoubaoAudioPacketizer.packetByteCount == 6_400)
        #expect(packets.map(\.count) == [3_200, 6_400])
        #expect(packetizer.flush()?.count == 3_320)
        #expect(packetizer.flush() == nil)
    }

    @Test func audioPacketizerResetRestoresFastFirstPacket() {
        var packetizer = DoubaoAudioPacketizer()

        #expect(packetizer.append(Data(count: 3_200)).map(\.count) == [3_200])
        #expect(packetizer.append(Data(count: 3_200)).isEmpty)
        packetizer.reset()
        #expect(packetizer.append(Data(count: 3_200)).map(\.count) == [3_200])
        #expect(packetizer.flush() == nil)
    }

    @Test func audioPacketizerPreservesOrderingAcrossArbitraryCallbackSizes() throws {
        var packetizer = DoubaoAudioPacketizer()
        let source = Data((0..<15_123).map { UInt8($0 % 251) })
        let callbackSizes = [1, 339, 1_024, 4_097, 2_111, 7_551]
        var offset = 0
        var output = Data()
        var packetSizes: [Int] = []

        for size in callbackSizes {
            let end = min(offset + size, source.count)
            guard offset < end else { break }
            for packet in packetizer.append(source.subdata(in: offset..<end)) {
                packetSizes.append(packet.count)
                output.append(packet)
            }
            offset = end
        }
        if offset < source.count {
            for packet in packetizer.append(source.subdata(in: offset..<source.count)) {
                packetSizes.append(packet.count)
                output.append(packet)
            }
        }
        if let remainder = packetizer.flush() {
            #expect(remainder.count < DoubaoAudioPacketizer.packetByteCount)
            output.append(remainder)
        }

        #expect(packetSizes == [3_200, 6_400])
        #expect(output == source)
    }

    @Test func wavPayloadExtractsRecordedPCMAndRejectsTheWrongFormat() throws {
        let pcm = Data((0..<12_346).map { UInt8($0 % 251) })
        let wav = makePCM16WAV(pcm: pcm)

        #expect(try DoubaoWAVPayload(data: wav).pcmData == pcm)
        #expect(throws: AudioProcessor.AudioProcessingError.self) {
            _ = try DoubaoWAVPayload(data: makePCM16WAV(pcm: pcm, channels: 2))
        }
    }

    @Test func cloudProviderReplaysCompleteAudioInsteadOfReturningUnsupportedProvider() async throws {
        let replay = DoubaoReplayTranscriberStub(result: "完整回退结果")
        let provider = DoubaoSpeechProvider(replayTranscriber: replay)
        let pcm = Data(repeating: 0x2A, count: 6_400)

        let result = try await provider.transcribe(
            audioData: makePCM16WAV(pcm: pcm),
            fileName: "recording.wav",
            apiKey: "test-key",
            model: DoubaoSpeechProvider.defaultResourceID,
            language: nil,
            customVocabulary: ["VoiceInk"],
            recognitionContext: nil
        )

        #expect(result == "完整回退结果")
        let invocation = try #require(await replay.invocation)
        #expect(invocation.wavByteCount > pcm.count)
        #expect(invocation.resourceID == DoubaoSpeechProvider.defaultResourceID)
        #expect(invocation.customVocabulary == ["VoiceInk"])
    }

    @Test func replayUsesOneFreshDoubaoConnectionAndPreservesEveryPCMByte() async throws {
        let pcm = Data((0..<15_124).map { UInt8($0 % 251) })
        let connection = DoubaoReplayTestConnection(finalText: "恢复成功")
        let connector = DoubaoReplayTestConnector(connection: connection)
        let pool = CloudSpeechConnectionPool(connector: connector)
        let transcriber = DoubaoWebSocketReplayTranscriber(
            connectionPool: pool,
            connector: connector,
            paceAudioInRealtime: false
        )

        let result = try await transcriber.transcribe(
            wavData: makePCM16WAV(pcm: pcm),
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            recognitionContext: nil
        )

        #expect(result == "恢复成功")
        #expect(connector.openCount == 1)
        let target = try #require(connector.lastTarget)
        guard case .doubao(_, let resourceID, let endpoint) = target else {
            Issue.record("Doubao replay opened a non-Doubao target")
            return
        }
        #expect(resourceID == DoubaoSpeechProvider.defaultResourceID)
        #expect(endpoint.host == "openspeech.bytedance.com")
        #expect(connection.audioPayload == pcm)
        #expect(connection.didSendFinalFrame)
    }

    @Test func fullFileRecoveryPublishesStreamingSnapshotsBeforeFinal() async throws {
        let connection = DoubaoReplayTestConnection(
            finalText: "恢复完成",
            partialText: "正在恢复",
            emitPartialBeforeFinalFrame: true
        )
        let connector = DoubaoReplayTestConnector(connection: connection)
        let partials = ThreadSafeStringProbe()
        let transcriber = DoubaoWebSocketReplayTranscriber(
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            paceAudioInRealtime: false,
            onPartialTranscript: { partials.append($0) }
        )

        let result = try await transcriber.transcribe(
            wavData: makePCM16WAV(pcm: Data(repeating: 0x33, count: 6_400)),
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            recognitionContext: nil
        )

        #expect(result == "恢复完成")
        #expect(partials.values == ["正在恢复"])
        #expect(connection.receiveCount == 2)
        #expect(connection.partialWasEmittedBeforeFinalFrame)
    }

    @Test func attemptCoordinatorNeverGrantsTwoDoubaoAttemptsAtOnce() async throws {
        let coordinator = DoubaoAttemptCoordinator()
        let firstID = UUID()
        let secondID = UUID()
        try await coordinator.acquire(firstID)

        let secondAcquire = Task {
            try await coordinator.acquire(secondID)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await coordinator.activeCount == 1)
        #expect(!secondAcquire.isCancelled)

        await coordinator.release(firstID)
        try await secondAcquire.value
        #expect(await coordinator.activeCount == 1)
        #expect(await coordinator.maximumObservedCount == 1)
        await coordinator.release(secondID)
        #expect(await coordinator.activeCount == 0)
    }

    @Test func attemptCoordinatorBoundsWaitBehindAStaleAttempt() async throws {
        let coordinator = DoubaoAttemptCoordinator()
        let firstID = UUID()
        try await coordinator.acquire(firstID)

        let startedAt = ContinuousClock.now
        do {
            try await coordinator.acquire(UUID(), timeout: .milliseconds(20))
            Issue.record("A stale Doubao attempt must not block a replacement forever")
        } catch let error as StreamingTranscriptionError {
            guard case .timeout = error else {
                Issue.record("Expected timeout while waiting behind a stale attempt")
                return
            }
        }
        #expect(startedAt.duration(to: .now) < .milliseconds(500))
        await coordinator.release(firstID)
    }

    @Test func credentialVerificationDoesNotWaitForTheLiveAttemptCoordinator() async throws {
        let coordinator = DoubaoAttemptCoordinator()
        let liveAttemptID = UUID()
        try await coordinator.acquire(liveAttemptID)
        let connection = DoubaoReplayTestConnection(finalText: "verified")
        let connector = DoubaoReplayTestConnector(connection: connection)
        let session = DoubaoWebSocketSession(
            eventsContinuation: nil,
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            attemptCoordinator: coordinator
        )

        try await session.connect(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .verification,
            startReceiving: false,
            allowPreconnectedConnection: false,
            coordinateAttempt: false
        )

        #expect(await coordinator.activeCount == 1)
        #expect(await session.observedConcurrentAttemptCount == nil)
        await session.disconnect()
        #expect(await coordinator.activeCount == 1)
        await coordinator.release(liveAttemptID)
    }

    @Test func cancelledLateConnectionCannotReopenAnOldSession() async throws {
        let coordinator = DoubaoAttemptCoordinator()
        let connection = DoubaoEarlyRecoveryConnection(finalText: "late")
        let connector = DoubaoBlockingRecoveryConnector(connection: connection)
        let session = DoubaoWebSocketSession(
            eventsContinuation: nil,
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            attemptCoordinator: coordinator
        )
        let connectTask = Task {
            try await session.connect(
                apiKey: "doubao-key",
                resourceID: DoubaoSpeechProvider.defaultResourceID,
                customVocabulary: [],
                settings: .defaults,
                endpoint: .optimizedStreaming,
                startReceiving: false,
                allowPreconnectedConnection: false
            )
        }

        try await connector.waitUntilOpenStarted()
        connectTask.cancel()
        await session.disconnect()
        await connector.releaseOpen()
        do {
            try await connectTask.value
            Issue.record("A cancelled late socket open must not reactivate the old session")
        } catch {
            // Expected: connect wraps the cancellation as a connection failure.
        }

        #expect(connection.isClosed)
        #expect(await coordinator.activeCount == 0)
    }

    @Test func cancellationDuringPreconnectionLeaseClosesTheLeasedSocket() async throws {
        let leasedConnection = DoubaoBlockingLeaseConnection()
        let connector = DoubaoLeaseCancellationConnector(leasedConnection: leasedConnection)
        let pool = CloudSpeechConnectionPool(connector: connector)
        let coordinator = DoubaoAttemptCoordinator()
        let target = CloudSpeechConnectionTarget.doubao(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            endpoint: DoubaoWebSocketSession.Endpoint.optimizedStreaming.url
        )
        await pool.reconcile(targets: [target])
        for _ in 0..<100 {
            if await pool.snapshot().readyKeys.contains(target.key) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pool.snapshot().readyKeys.contains(target.key))

        let session = DoubaoWebSocketSession(
            eventsContinuation: nil,
            connectionPool: pool,
            connector: connector,
            attemptCoordinator: coordinator
        )
        let connectTask = Task {
            try await session.connect(
                apiKey: "doubao-key",
                resourceID: DoubaoSpeechProvider.defaultResourceID,
                customVocabulary: [],
                settings: .defaults,
                endpoint: .optimizedStreaming,
                startReceiving: false
            )
        }

        try await leasedConnection.waitUntilPingStarted()
        connectTask.cancel()
        leasedConnection.releasePing()
        do {
            try await connectTask.value
            Issue.record("A cancelled lease must not leave its socket unowned")
        } catch {
            // Expected cancellation from the post-lease ownership check.
        }

        #expect(leasedConnection.isClosed)
        #expect(await coordinator.activeCount == 0)
        await pool.shutdown()
    }

    @Test func replayFinalTimeoutStartsOnlyAfterItIsArmed() async throws {
        let connection = DoubaoBlockingFinalConnection()
        let connector = SingleDoubaoConnectionConnector(connection: connection)
        let session = DoubaoWebSocketSession(
            eventsContinuation: nil,
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            attemptCoordinator: DoubaoAttemptCoordinator()
        )
        try await session.connect(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .optimizedStreaming,
            startReceiving: false,
            allowPreconnectedConnection: false
        )
        let finalTask = Task {
            try await session.receiveFinalTranscript(timeout: nil)
        }

        for _ in 0..<100 where !connection.receiveStarted {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!connection.isClosed)

        await session.armFinalResultTimeout(after: .milliseconds(20))
        do {
            _ = try await finalTask.value
            Issue.record("An armed final-response deadline must close a silent socket")
        } catch let error as StreamingTranscriptionError {
            guard case .timeout = error else {
                Issue.record("Expected a final-response timeout")
                return
            }
        }
        #expect(connection.isClosed)
        await session.disconnect()
    }

    @Test func replayFinalTimeoutSurvivesArmingBeforeReceiverStartup() async throws {
        let connection = DoubaoBlockingFinalConnection()
        let connector = SingleDoubaoConnectionConnector(connection: connection)
        let session = DoubaoWebSocketSession(
            eventsContinuation: nil,
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            attemptCoordinator: DoubaoAttemptCoordinator()
        )
        try await session.connect(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .optimizedStreaming,
            startReceiving: false,
            allowPreconnectedConnection: false
        )

        await session.armFinalResultTimeout(after: .milliseconds(20))
        do {
            _ = try await session.receiveFinalTranscript(timeout: nil)
            Issue.record("Receiver startup must preserve an already armed deadline")
        } catch let error as StreamingTranscriptionError {
            guard case .timeout = error else {
                Issue.record("Expected a final-response timeout")
                return
            }
        }
        #expect(connection.isClosed)
        await session.disconnect()
    }

    @Test func replayFinalTimeoutReturnsTheLatestFullyStableSnapshot() async throws {
        let connection = DoubaoStableThenBlockingConnection(stableText: "完整稳定结果")
        let connector = SingleDoubaoConnectionConnector(connection: connection)
        let session = DoubaoWebSocketSession(
            eventsContinuation: nil,
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            attemptCoordinator: DoubaoAttemptCoordinator()
        )
        try await session.connect(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .optimizedStreaming,
            startReceiving: false,
            allowPreconnectedConnection: false
        )

        let finalTask = Task {
            try await session.receiveFinalTranscript(timeout: nil)
        }
        for _ in 0..<100 where connection.receiveCount < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        await session.armFinalResultTimeout(after: .milliseconds(20))

        #expect(try await finalTask.value == "完整稳定结果")
        #expect(connection.isClosed)
        await session.disconnect()
    }

    @Test func cancellingRecoveryClosesReceiveImmediately() async throws {
        let connection = DoubaoBlockingFinalConnection()
        let connector = SingleDoubaoConnectionConnector(connection: connection)
        let transcriber = DoubaoWebSocketReplayTranscriber(
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector,
            paceAudioInRealtime: false
        )
        let task = Task {
            try await transcriber.transcribe(
                wavData: makePCM16WAV(pcm: Data(repeating: 0x44, count: 3_200)),
                apiKey: "doubao-key",
                resourceID: DoubaoSpeechProvider.defaultResourceID,
                customVocabulary: [],
                settings: .defaults,
                recognitionContext: nil
            )
        }

        for _ in 0..<100 where !connection.receiveStarted {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(connection.receiveStarted)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled recovery must not produce a transcript")
        } catch is CancellationError {
            // Expected.
        }
        #expect(connection.isClosed)
        #expect(cancelledAt.duration(to: .now) < .milliseconds(500))
    }

    @Test func finalFrameEndsReceiveLoopWithoutTurningNormalServerCloseIntoAnError() async throws {
        let connection = DoubaoReplayTestConnection(finalText: "最终结果")
        let connector = DoubaoReplayTestConnector(connection: connection)
        let (events, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        let session = DoubaoWebSocketSession(
            eventsContinuation: continuation,
            connectionPool: CloudSpeechConnectionPool(connector: connector),
            connector: connector
        )

        try await session.connect(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .optimizedStreaming,
            startReceiving: true,
            allowPreconnectedConnection: false
        )
        try await session.sendAudioChunk(Data(repeating: 0x01, count: 3_200))
        try await session.commit()

        var committedText: String?
        for await event in events {
            if case .committed(let text) = event {
                committedText = text
                break
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(committedText == "最终结果")
        #expect(connection.receiveCount == 1)
        await session.disconnect()
        continuation.finish()
    }

    @Test func stalePreconnectionRecoversBeforeRecordingEndsAndReplaysBufferedAudio() async throws {
        let staleConnector = DoubaoStalePreconnectionConnector()
        let freshConnection = DoubaoEarlyRecoveryConnection(finalText: "即时恢复成功")
        let freshConnector = DoubaoBlockingRecoveryConnector(connection: freshConnection)
        let pool = CloudSpeechConnectionPool(connector: staleConnector)
        let target = CloudSpeechConnectionTarget.doubao(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            endpoint: DoubaoWebSocketSession.Endpoint.optimizedStreaming.url
        )
        await pool.reconcile(targets: [target])
        for _ in 0..<100 {
            if await pool.snapshot().readyKeys.contains(target.key) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pool.snapshot().readyKeys.contains(target.key))

        let (events, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        let eventProbe = DoubaoEarlyRecoveryEventProbe()
        let eventTask = Task {
            for await event in events {
                eventProbe.record(event)
            }
        }
        let session = DoubaoWebSocketSession(
            eventsContinuation: continuation,
            connectionPool: pool,
            connector: freshConnector
        )

        try await session.connect(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .optimizedStreaming,
            startReceiving: true
        )
        try await freshConnector.waitUntilOpenStarted()

        let firstChunk = Data((0..<3_200).map { UInt8($0 % 251) })
        let secondChunk = Data((0..<7_913).map { UInt8(($0 + 17) % 251) })
        try await session.sendAudioChunk(firstChunk)
        try await session.sendAudioChunk(secondChunk)
        try await session.commit()
        await freshConnector.releaseOpen()

        for _ in 0..<200 {
            if eventProbe.committedText != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(eventProbe.committedText == "即时恢复成功")
        #expect(eventProbe.errors.isEmpty)
        #expect(await freshConnector.openCount == 1)
        #expect(freshConnection.audioPayload == firstChunk + secondChunk)
        #expect(freshConnection.didSendFinalFrame)

        await session.disconnect()
        continuation.finish()
        eventTask.cancel()
        await pool.shutdown()
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

    @Test func APIKeyManagerLoadsMultipleValuesFromOneKeychainBundle() throws {
        let bundleKey = "keychainBundle-\(UUID().uuidString)"
        let firstModelID = UUID()
        let secondModelID = UUID()
        defer {
            _ = KeychainService.shared.delete(
                forKey: bundleKey,
                syncable: false,
                storagePolicy: .keychainOnly
            )
        }

        let writer = APIKeyManager(
            bundleKeyIdentifier: bundleKey,
            protectsUserCredentialsDuringTests: false
        )
        #expect(
            writer.saveCustomModelAPIKey(
                "first-batch-value",
                forModelId: firstModelID
            )
        )
        #expect(
            writer.saveCustomModelAPIKey(
                "second-batch-value",
                forModelId: secondModelID
            )
        )

        let reader = APIKeyManager(
            bundleKeyIdentifier: bundleKey,
            protectsUserCredentialsDuringTests: false
        )
        #expect(reader.preloadAllAPIKeys())
        #expect(reader.getCustomModelAPIKey(forModelId: firstModelID) == "first-batch-value")
        #expect(reader.getCustomModelAPIKey(forModelId: secondModelID) == "second-batch-value")
    }

    @Test func APIKeyManagerLaunchPreloadDoesNotBlockOrFanOutToLegacyItems() throws {
        let bundleKey = "backgroundBundle-\(UUID().uuidString)"
        let store = APIKeyKeychainStoreStub()
        store.blocksReads = true
        store.readResult = .value(try JSONEncoder().encode(["deepgramAPIKey": "background-value"]))
        let queue = DispatchQueue(label: "VoiceInkTests.APIKeyPreload.\(UUID().uuidString)")
        let manager = APIKeyManager(
            bundleKeyIdentifier: bundleKey,
            protectsUserCredentialsDuringTests: false,
            keychain: store,
            preloadQueue: queue
        )
        let completed = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .aiProviderKeyChanged,
            object: manager,
            queue: nil
        ) { _ in
            completed.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.preloadAllAPIKeysInBackground()

        #expect(store.readStarted.wait(timeout: .now() + 1) == .success)
        #expect(manager.getAPIKey(forProvider: "Deepgram", allowAuthenticationUI: true) == nil)
        #expect(store.readKeys == [bundleKey])

        store.allowReadToFinish.signal()
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(manager.getAPIKey(forProvider: "Deepgram") == "background-value")
        #expect(store.readKeys == [bundleKey])
    }

    @Test func APIKeyManagerDoesNotRetryRejectedLaunchAccess() {
        let bundleKey = "rejectedBundle-\(UUID().uuidString)"
        let store = APIKeyKeychainStoreStub()
        store.readResult = .unavailable(errSecAuthFailed)
        let manager = APIKeyManager(
            bundleKeyIdentifier: bundleKey,
            protectsUserCredentialsDuringTests: false,
            keychain: store
        )
        let completed = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .aiProviderKeyChanged,
            object: manager,
            queue: nil
        ) { _ in
            completed.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.preloadAllAPIKeysInBackground()

        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(manager.getAPIKey(forProvider: "Deepgram", allowAuthenticationUI: true) == nil)
        #expect(manager.getAPIKey(forProvider: "Gemini", allowAuthenticationUI: true) == nil)
        #expect(store.readKeys == [bundleKey])
    }

    @Test func APIKeyManagerWritesOnlyTheConsolidatedBundle() {
        let bundleKey = "singleBundle-\(UUID().uuidString)"
        let store = APIKeyKeychainStoreStub()
        let manager = APIKeyManager(
            bundleKeyIdentifier: bundleKey,
            protectsUserCredentialsDuringTests: false,
            keychain: store
        )

        #expect(manager.preloadAllAPIKeys())
        #expect(manager.saveAPIKey("new-value", forProvider: "Deepgram"))
        #expect(store.savedKeys == [bundleKey])
    }

    @Test func APIKeyManagerDoesNotOverwriteAnUnreadableBundle() throws {
        let bundleKey = "invalidKeychainBundle-\(UUID().uuidString)"
        let invalidData = Data("not-json".utf8)
        defer {
            _ = KeychainService.shared.delete(
                forKey: bundleKey,
                syncable: false,
                storagePolicy: .keychainOnly
            )
        }

        #expect(
            KeychainService.shared.save(
                data: invalidData,
                forKey: bundleKey,
                syncable: false,
                storagePolicy: .keychainOnly
            )
        )

        let manager = APIKeyManager(
            bundleKeyIdentifier: bundleKey,
            protectsUserCredentialsDuringTests: false
        )
        #expect(!manager.saveCustomModelAPIKey("must-not-be-written", forModelId: UUID()))
        #expect(
            KeychainService.shared.getData(
                forKey: bundleKey,
                syncable: false,
                storagePolicy: .keychainOnly
            ) == invalidData
        )
    }

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

    private func makePCM16WAV(pcm: Data, channels: UInt16 = 1) -> Data {
        var wav = Data("RIFF".utf8)
        appendUInt32LE(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendUInt32LE(16, to: &wav)
        appendUInt16LE(1, to: &wav)
        appendUInt16LE(channels, to: &wav)
        appendUInt32LE(16_000, to: &wav)
        appendUInt32LE(UInt32(16_000 * Int(channels) * MemoryLayout<Int16>.size), to: &wav)
        appendUInt16LE(UInt16(Int(channels) * MemoryLayout<Int16>.size), to: &wav)
        appendUInt16LE(16, to: &wav)
        wav.append(Data("data".utf8))
        appendUInt32LE(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

private final class DoubaoEarlyRecoveryEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommittedText: String?
    private var storedErrors: [Error] = []

    var committedText: String? { lock.withLock { storedCommittedText } }
    var errors: [Error] { lock.withLock { storedErrors } }

    func record(_ event: StreamingTranscriptionEvent) {
        lock.withLock {
            switch event {
            case .committed(let text):
                storedCommittedText = text
            case .error(let error):
                storedErrors.append(error)
            default:
                break
            }
        }
    }
}

private final class DoubaoStalePreconnectionConnector: CloudSpeechWebSocketConnecting,
    @unchecked Sendable
{
    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        DoubaoStalePreconnection()
    }
}

private final class DoubaoStalePreconnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    func send(_: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: 54,
            userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"]
        )
    }

    func ping(timeout _: Duration) async throws {}
    func close() {}
}

private actor DoubaoBlockingRecoveryConnector: CloudSpeechWebSocketConnecting {
    private let connection: DoubaoEarlyRecoveryConnection
    private var openContinuation: CheckedContinuation<Void, Never>?
    private(set) var openCount = 0
    private var didStartOpening = false

    init(connection: DoubaoEarlyRecoveryConnection) {
        self.connection = connection
    }

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        openCount += 1
        didStartOpening = true
        await withCheckedContinuation { continuation in
            openContinuation = continuation
        }
        return connection
    }

    func waitUntilOpenStarted() async throws {
        for _ in 0..<100 {
            if didStartOpening { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StreamingTranscriptionError.timeout
    }

    func releaseOpen() {
        let continuation = openContinuation
        openContinuation = nil
        continuation?.resume()
    }
}

private final class DoubaoEarlyRecoveryConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let finalText: String
    private var storedAudioPayload = Data()
    private var storedDidSendFinalFrame = false
    private var storedIsClosed = false

    init(finalText: String) {
        self.finalText = finalText
    }

    var audioPayload: Data { lock.withLock { storedAudioPayload } }
    var didSendFinalFrame: Bool { lock.withLock { storedDidSendFinalFrame } }
    var isClosed: Bool { lock.withLock { storedIsClosed } }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .data(let data) = message, data.count >= 8 else { return }
        switch data[data.startIndex + 1] {
        case 0x20:
            lock.withLock {
                storedAudioPayload.append(contentsOf: data.dropFirst(8))
            }
        case 0x22:
            lock.withLock {
                storedDidSendFinalFrame = true
            }
        default:
            break
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while !didSendFinalFrame {
            try await Task.sleep(for: .milliseconds(1))
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": ["text": finalText, "utterances": []] as [String: Any]
        ])
        var frame = Data([0x11, 0x93, 0x10, 0x00])
        appendUInt32(1, to: &frame)
        appendUInt32(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return .data(frame)
    }

    func ping(timeout _: Duration) async throws {}
    func close() {
        lock.withLock { storedIsClosed = true }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

private actor DoubaoReplayTranscriberStub: DoubaoReplayTranscribing {
    struct Invocation: Sendable {
        let wavByteCount: Int
        let resourceID: String
        let customVocabulary: [String]
    }

    private let result: String
    private(set) var invocation: Invocation?

    init(result: String) {
        self.result = result
    }

    func transcribe(
        wavData: Data,
        apiKey _: String,
        resourceID: String,
        customVocabulary: [String],
        settings _: DoubaoSpeechSettings,
        recognitionContext _: RecognitionContextEnvelope?
    ) async throws -> String {
        invocation = Invocation(
            wavByteCount: wavData.count,
            resourceID: resourceID,
            customVocabulary: customVocabulary
        )
        return result
    }
}

private final class DoubaoReplayTestConnector: CloudSpeechWebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: DoubaoReplayTestConnection
    private var storedOpenCount = 0
    private var storedLastTarget: CloudSpeechConnectionTarget?

    init(connection: DoubaoReplayTestConnection) {
        self.connection = connection
    }

    var openCount: Int { lock.withLock { storedOpenCount } }
    var lastTarget: CloudSpeechConnectionTarget? { lock.withLock { storedLastTarget } }

    func open(
        target: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        lock.withLock {
            storedOpenCount += 1
            storedLastTarget = target
        }
        return connection
    }
}

private final class DoubaoReplayTestConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let finalText: String
    private let partialText: String?
    private let emitPartialBeforeFinalFrame: Bool
    private var storedAudioPayload = Data()
    private var storedDidSendFinalFrame = false
    private var storedReceiveCount = 0
    private var storedPartialWasEmittedBeforeFinalFrame = false

    init(
        finalText: String,
        partialText: String? = nil,
        emitPartialBeforeFinalFrame: Bool = false
    ) {
        self.finalText = finalText
        self.partialText = partialText
        self.emitPartialBeforeFinalFrame = emitPartialBeforeFinalFrame
    }

    var audioPayload: Data { lock.withLock { storedAudioPayload } }
    var didSendFinalFrame: Bool { lock.withLock { storedDidSendFinalFrame } }
    var receiveCount: Int { lock.withLock { storedReceiveCount } }
    var partialWasEmittedBeforeFinalFrame: Bool {
        lock.withLock { storedPartialWasEmittedBeforeFinalFrame }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .data(let data) = message, data.count >= 8 else { return }
        let messageTypeAndFlags = data[data.startIndex + 1]
        if messageTypeAndFlags == 0x20 {
            lock.withLock {
                storedAudioPayload.append(contentsOf: data.dropFirst(8))
            }
        } else if messageTypeAndFlags == 0x22 {
            if emitPartialBeforeFinalFrame {
                // The production replay is paced, which gives the concurrently
                // created receive task time to start before commit. This test
                // disables pacing, so wait briefly for that task instead of
                // making the assertion depend on executor scheduling.
                for _ in 0..<100 where receiveCount == 0 {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            lock.withLock {
                storedDidSendFinalFrame = true
            }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let receiveCount = lock.withLock {
            storedReceiveCount += 1
            return storedReceiveCount
        }
        let isPartial = receiveCount == 1 && partialText != nil
        if isPartial && emitPartialBeforeFinalFrame {
            lock.withLock {
                storedPartialWasEmittedBeforeFinalFrame = !storedDidSendFinalFrame
            }
        } else {
            while !didSendFinalFrame {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let responseText = isPartial ? partialText! : finalText
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": ["text": responseText, "utterances": []] as [String: Any]
        ])
        var frame = Data([0x11, isPartial ? 0x91 : 0x93, 0x10, 0x00])
        appendUInt32(1, to: &frame)
        appendUInt32(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return .data(frame)
    }

    func ping(timeout _: Duration) async throws {}
    func close() {}

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

private final class ThreadSafeStringProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] { lock.withLock { storedValues } }

    func append(_ value: String) {
        lock.withLock { storedValues.append(value) }
    }
}

private final class SingleDoubaoConnectionConnector: CloudSpeechWebSocketConnecting, @unchecked Sendable {
    private let connection: any CloudSpeechWebSocketConnection

    init(connection: any CloudSpeechWebSocketConnection) {
        self.connection = connection
    }

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        connection
    }
}

private actor DoubaoLeaseCancellationConnector: CloudSpeechWebSocketConnecting {
    private let leasedConnection: DoubaoBlockingLeaseConnection
    private var openCount = 0

    init(leasedConnection: DoubaoBlockingLeaseConnection) {
        self.leasedConnection = leasedConnection
    }

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed _: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        openCount += 1
        if openCount == 1 {
            return leasedConnection
        }
        return DoubaoReplayTestConnection(finalText: "replacement")
    }
}

private final class DoubaoBlockingLeaseConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var pingContinuation: CheckedContinuation<Void, Never>?
    private var storedPingStarted = false
    private var storedIsClosed = false

    var isClosed: Bool { lock.withLock { storedIsClosed } }

    func send(_: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw StreamingTranscriptionError.notConnected
    }

    func ping(timeout _: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                storedPingStarted = true
                pingContinuation = continuation
            }
        }
    }

    func waitUntilPingStarted() async throws {
        for _ in 0..<100 {
            if lock.withLock({ storedPingStarted }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StreamingTranscriptionError.timeout
    }

    func releasePing() {
        let continuation = lock.withLock {
            defer { pingContinuation = nil }
            return pingContinuation
        }
        continuation?.resume()
    }

    func close() {
        lock.withLock { storedIsClosed = true }
    }
}

private final class DoubaoBlockingFinalConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var storedReceiveStarted = false
    private var storedIsClosed = false

    var receiveStarted: Bool { lock.withLock { storedReceiveStarted } }
    var isClosed: Bool { lock.withLock { storedIsClosed } }

    func send(_: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let shouldCancel = lock.withLock {
                storedReceiveStarted = true
                if storedIsClosed { return true }
                receiveContinuation = continuation
                return false
            }
            if shouldCancel {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func ping(timeout _: Duration) async throws {}

    func close() {
        let continuation = lock.withLock {
            storedIsClosed = true
            defer { receiveContinuation = nil }
            return receiveContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class DoubaoStableThenBlockingConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let stableText: String
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var storedReceiveCount = 0
    private var storedIsClosed = false

    init(stableText: String) {
        self.stableText = stableText
    }

    var receiveCount: Int { lock.withLock { storedReceiveCount } }
    var isClosed: Bool { lock.withLock { storedIsClosed } }

    func send(_: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let count = lock.withLock {
            storedReceiveCount += 1
            return storedReceiveCount
        }
        if count == 1 {
            let payload = try JSONSerialization.data(withJSONObject: [
                "result": [
                    "text": stableText,
                    "utterances": [["text": stableText, "definite": true]],
                ] as [String: Any]
            ])
            var frame = Data([0x11, 0x91, 0x10, 0x00])
            appendUInt32(1, to: &frame)
            appendUInt32(UInt32(payload.count), to: &frame)
            frame.append(payload)
            return .data(frame)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let shouldCancel = lock.withLock {
                if storedIsClosed { return true }
                receiveContinuation = continuation
                return false
            }
            if shouldCancel {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func ping(timeout _: Duration) async throws {}

    func close() {
        let continuation = lock.withLock {
            storedIsClosed = true
            defer { receiveContinuation = nil }
            return receiveContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
