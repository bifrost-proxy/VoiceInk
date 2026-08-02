import Testing
@testable import VoiceInk

struct TranscriptionRealtimeSupportTests {
    @Test func distinguishesContinuousStreamingFromSlidingWindowsAndBatchModels() throws {
        let models = TranscriptionModelRegistry.models

        let unified = try #require(models.first { $0.name == "parakeet-unified-0.6b" })
        let nemotron = try #require(models.first { $0.name == "nemotron-multilingual-0.6b" })
        let parakeet = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        let senseVoice = try #require(models.first { $0.name == "sensevoice-small" })
        let qwen3 = try #require(models.first { $0.name == "qwen3-asr-0.6b-int8" })
        let whisper = try #require(models.first { $0.name == "ggml-small" })

        #expect(TranscriptionRealtimeSupport.mode(for: unified) == .continuousStreaming)
        #expect(TranscriptionRealtimeSupport.mode(for: nemotron) == .continuousStreaming)
        #expect(TranscriptionRealtimeSupport.mode(for: parakeet) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: senseVoice) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: qwen3) == .slidingWindow)
        #expect(TranscriptionRealtimeSupport.mode(for: whisper) == .batchOnly)
    }

    @Test func streamingCloudModelsUseContinuousStreaming() {
        let streamingCloudModels = TranscriptionModelRegistry.models.compactMap { $0 as? CloudModel }
            .filter(\.supportsStreaming)

        #expect(!streamingCloudModels.isEmpty)
        for model in streamingCloudModels {
            #expect(TranscriptionRealtimeSupport.mode(for: model) == .continuousStreaming)
        }
    }
}
