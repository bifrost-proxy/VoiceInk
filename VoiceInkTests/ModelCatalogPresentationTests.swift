import Foundation
import Testing
@testable import VoiceInk

struct ModelCatalogPresentationTests {
    @Test func localModelsSortBySpeedThenAccuracy() throws {
        let models = TranscriptionModelRegistry.models
        let unified = try #require(models.first { $0.name == "parakeet-unified-0.6b" })
        let v2 = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v2" })
        let chineseCTC = try #require(models.first { $0.name == "parakeet-ctc-0.6b-zh-cn" })
        let paraformer = try #require(models.first { $0.name == "paraformer-large-zh" })

        let sorted = ModelCatalogOrdering.localModelsByPerformance([paraformer, v2, chineseCTC, unified])
        #expect(sorted.map(\.name) == [
            "parakeet-unified-0.6b", // Same 9.9 speed as V2, higher accuracy.
            "parakeet-tdt-0.6b-v2",
            "parakeet-ctc-0.6b-zh-cn",
            "paraformer-large-zh",
        ])
    }

    @Test func languageCapabilitiesRecognizeChineseAndEnglishVariants() throws {
        let models = TranscriptionModelRegistry.models
        let qwen = try #require(models.first { $0.name == "qwen3-asr-0.6b-int8" })
        let qwenMLX = try #require(models.first { $0.name == "qwen3-asr-0.6b-mlx-streaming" })
        let chineseCTC = try #require(models.first { $0.name == "parakeet-ctc-0.6b-zh-cn" })
        let englishOnly = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v2" })

        #expect(ModelLanguageSupportCatalog.supportsChinese(qwen))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(qwen))
        #expect(ModelLanguageSupportCatalog.supportsChinese(qwenMLX))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(qwenMLX))
        #expect(ModelLanguageSupportCatalog.supportsChinese(chineseCTC))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(chineseCTC))
        #expect(!ModelLanguageSupportCatalog.supportsChinese(englishOnly))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(englishOnly))

        #expect(
            ModelLanguageSupportCatalog.summary(for: qwen) == [
                String(localized: "Chinese"),
                String(localized: "English"),
                String(localized: "More languages"),
            ].joined(separator: " · ")
        )
        #expect(ModelLanguageSupportCatalog.summary(for: qwenMLX) == ModelLanguageSupportCatalog.summary(for: qwen))
        #expect(ModelLanguageSupportCatalog.languageCount(for: qwenMLX) == 52)
        #expect(ModelLanguageSupportCatalog.sections(for: qwenMLX).map(\.id) == ["languages", "dialects"])
        #expect(
            ModelLanguageSupportCatalog.summary(for: chineseCTC) == [
                String(localized: "Chinese"),
                String(localized: "English"),
            ].joined(separator: " · ")
        )
    }

    @Test func qwenCPUAndMLXAreSeparateCatalogChoices() throws {
        let models = TranscriptionModelRegistry.models
        let cpu = try #require(models.first { $0.name == "qwen3-asr-0.6b-int8" })
        let mlx = try #require(models.first { $0.name == "qwen3-asr-0.6b-mlx-streaming" })

        #expect(cpu is SherpaOnnxModel)
        #expect(mlx is QwenMLXModel)
        #expect(cpu.id != mlx.id)
        #expect(cpu.displayName.contains("INT8"))
        #expect(mlx.displayName.contains("MLX Streaming"))
        let mlxPerformance = ModelCatalogOrdering.performance(for: mlx)
        let cpuPerformance = ModelCatalogOrdering.performance(for: cpu)
        #expect(cpuPerformance.accuracy == 0.96)
        #expect(mlxPerformance.speed == 0.95)
        #expect(mlxPerformance.accuracy == 0.96)

        let paraformer = try #require(models.first { $0.name == "paraformer-large-zh" })
        let qwenOrder = ModelCatalogOrdering.localModelsByPerformance([paraformer, mlx])
        #expect(qwenOrder.map(\.name) == [mlx.name, paraformer.name])
    }

    @Test func zipformerExposesOfficialAccuracyEvidence() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "sherpa-zipformer-ctc-zh-int8" }
                as? SherpaOnnxModel
        )

        #expect(model.accuracy == 0.94)
        #expect(ModelCatalogOrdering.performance(for: model).accuracy == 0.94)
        #expect(
            model.accuracyBenchmarkSummary
                == "官方 WER：AISHELL 1.74 · WenetSpeech 网络 5.92 / 会议 7.75"
        )
    }
}
