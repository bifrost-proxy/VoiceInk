import Foundation
import Testing
@testable import VoiceInk

struct ModelOfficialSourceCatalogTests {
    @Test func everyDownloadableBundledModelHasAnOfficialHTTPSPage() {
        let downloadableProviders: Set<ModelProvider> = [.fluidAudio, .sherpaOnnx, .qwenMlx, .whisper]
        let downloadableModels = TranscriptionModelRegistry.models.filter {
            downloadableProviders.contains($0.provider)
        }

        #expect(!downloadableModels.isEmpty)
        for model in downloadableModels {
            #expect(model.officialSourceURL?.scheme == "https", "Missing official source for \(model.name)")
        }
    }

    @Test func officialPagesUseTheExpectedModelSuppliers() throws {
        let models = TranscriptionModelRegistry.models

        let parakeet = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        #expect(parakeet.officialSourceURL?.host == "huggingface.co")
        #expect(parakeet.officialSourceURL?.path.hasPrefix("/nvidia/") == true)

        let qwen = try #require(models.first { $0.name == "qwen3-asr-0.6b-int8" })
        #expect(qwen.officialSourceURL?.path.hasPrefix("/Qwen/") == true)
        let qwenMLXINT8 = try #require(models.first { $0.name == "qwen3-asr-0.6b-mlx-int8-streaming" })
        #expect(qwenMLXINT8.officialSourceURL?.path.hasPrefix("/mlx-community/") == true)
        let qwenMLXFP16 = try #require(models.first { $0.name == "qwen3-asr-0.6b-mlx-streaming" })
        #expect(qwenMLXFP16.officialSourceURL?.path.hasPrefix("/Qwen/") == true)

        let whisper = try #require(models.first { $0.name == "ggml-small" })
        #expect(whisper.officialSourceURL?.absoluteString == "https://github.com/openai/whisper")
    }
}
