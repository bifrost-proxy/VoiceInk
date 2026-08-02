import Testing
@testable import VoiceInk

struct TranscriptionRealtimeSupportTests {
    @Test func distinguishesNativeStreamingFromSlidingWindowsAndBatchModels() throws {
        let models = TranscriptionModelRegistry.models

        let unified = try #require(models.first { $0.name == "parakeet-unified-0.6b" })
        let nemotron = try #require(models.first { $0.name == "nemotron-multilingual-0.6b" })
        let parakeetV2 = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v2" })
        let parakeetV3 = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        let parakeetCtcZhCn = try #require(models.first { $0.name == "parakeet-ctc-0.6b-zh-cn" })
        let senseVoice = try #require(models.first { $0.name == "sensevoice-small" })
        let paraformer = try #require(models.first { $0.name == "paraformer-large-zh" })
        let qwen3 = try #require(models.first { $0.name == "qwen3-asr-0.6b-int8" })
        let whisper = try #require(models.first { $0.name == "ggml-small" })

        #expect(TranscriptionRealtimeSupport.mode(for: unified) == .nativeStreaming)
        #expect(TranscriptionRealtimeSupport.mode(for: nemotron) == .nativeStreaming)
        #expect(TranscriptionRealtimeSupport.mode(for: parakeetV2) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: parakeetV3) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: parakeetCtcZhCn) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: senseVoice) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: paraformer) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: qwen3) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: whisper) == .batchOnly)

        let qwenModel = try #require(qwen3 as? SherpaOnnxModel)
        #expect(qwenModel.speed == 0.97)
    }

    @Test func streamingCloudModelsUseNativeStreaming() {
        let streamingCloudModels = TranscriptionModelRegistry.models.compactMap { $0 as? CloudModel }
            .filter(\.supportsStreaming)

        #expect(!streamingCloudModels.isEmpty)
        for model in streamingCloudModels {
            #expect(TranscriptionRealtimeSupport.mode(for: model) == .nativeStreaming)
        }
    }

    @Test func chineseCtcDetokenizationRemovesArtificialCharacterSpacing() {
        #expect(
            ParakeetCtcZhCnManager.detokenize("你 好 ， 世 界 。")
                == "你好，世界。"
        )
        #expect(
            ParakeetCtcZhCnManager.detokenize("What are you doing ? 这 是 测 试 。")
                == "What are you doing? 这是测试。"
        )
    }

    @Test func chineseCtcPreviewStartsEarlyWithoutPrematurePauseFinalization() {
        let configuration = BufferedOnDeviceStreamingProvider.Configuration.fastPreview

        #expect(configuration.minimumSamples == 8_000)
        #expect(configuration.minimumNewSamples == 8_000)
        #expect(configuration.maximumSegmentSamples == 240_000)
        #expect(!configuration.finalizesAtPause)
    }

    @Test func bufferedPreviewKeepsBriefPausesProvisional() {
        #expect(!BufferedOnDeviceStreamingProvider.Configuration.default.finalizesAtPause)
    }

    @Test func bufferedRealtimeMigrationPreservesChineseCtcSelection() {
        let configuration = ModeConfig(
            name: "Chinese dictation",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: "parakeet-ctc-0.6b-zh-cn",
            isRealtimeTranscriptionEnabled: false
        )

        let result = BufferedRealtimeModeMigration.migrate(
            configuration,
            shouldMigrate: true
        )

        #expect(result.foundBufferedRealtimeModel)
        #expect(result.configuration.selectedTranscriptionModelName == "parakeet-ctc-0.6b-zh-cn")
        #expect(result.configuration.isRealtimeTranscriptionEnabled)
    }
}
