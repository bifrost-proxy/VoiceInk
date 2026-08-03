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
        let qwenMLXINT8 = try #require(models.first { $0.name == "qwen3-asr-0.6b-mlx-int8-streaming" })
        let qwenMLXFP16 = try #require(models.first { $0.name == "qwen3-asr-0.6b-mlx-streaming" })
        let chineseCTC = try #require(models.first { $0.name == "parakeet-ctc-0.6b-zh-cn" })
        let englishOnly = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v2" })

        #expect(ModelLanguageSupportCatalog.supportsChinese(qwen))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(qwen))
        #expect(ModelLanguageSupportCatalog.supportsChinese(qwenMLXINT8))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(qwenMLXINT8))
        #expect(ModelLanguageSupportCatalog.supportsChinese(qwenMLXFP16))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(qwenMLXFP16))
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
        for qwenMLX in [qwenMLXINT8, qwenMLXFP16] {
            #expect(ModelLanguageSupportCatalog.summary(for: qwenMLX) == ModelLanguageSupportCatalog.summary(for: qwen))
            #expect(ModelLanguageSupportCatalog.languageCount(for: qwenMLX) == 52)
            #expect(ModelLanguageSupportCatalog.sections(for: qwenMLX).map(\.id) == ["languages", "dialects"])
        }
        #expect(
            ModelLanguageSupportCatalog.summary(for: chineseCTC) == [
                String(localized: "Chinese"),
                String(localized: "English"),
            ].joined(separator: " · ")
        )
    }

    @Test func qwenCPUAndMLXPrecisionsAreSeparateCatalogChoices() throws {
        let models = TranscriptionModelRegistry.models
        let cpu = try #require(models.first { $0.name == "qwen3-asr-0.6b-int8" })
        let mlxINT8 = try #require(
            models.first { $0.name == "qwen3-asr-0.6b-mlx-int8-streaming" } as? QwenMLXModel
        )
        let mlxFP16 = try #require(
            models.first { $0.name == "qwen3-asr-0.6b-mlx-streaming" } as? QwenMLXModel
        )

        #expect(cpu is SherpaOnnxModel)
        #expect(cpu.id != mlxINT8.id)
        #expect(mlxINT8.id != mlxFP16.id)
        #expect(cpu.displayName.contains("INT8"))
        #expect(mlxINT8.displayName.contains("INT8"))
        #expect(mlxFP16.displayName.contains("FP16"))
        #expect(mlxINT8.precision == .int8)
        #expect(mlxFP16.precision == .fp16)
        #expect(mlxINT8.precision.isRecommended)
        #expect(!mlxFP16.precision.isRecommended)
        #expect(mlxINT8.repositoryID != mlxFP16.repositoryID)
        #expect(mlxINT8.revision != mlxFP16.revision)
        #expect(mlxINT8.modelSHA256 != mlxFP16.modelSHA256)
        #expect(mlxINT8.expectedDownloadBytes < mlxFP16.expectedDownloadBytes)
        #expect(QwenMLXPaths.modelDirectory(for: mlxINT8) != QwenMLXPaths.modelDirectory(for: mlxFP16))
        #expect(mlxINT8.repositoryID == "mlx-community/Qwen3-ASR-0.6B-8bit")
        #expect(mlxINT8.revision == "89e96d92ba34aca20b3e29fb10cc284097d1219f")
        #expect(mlxINT8.modelSHA256 == "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8")
        let mlxPerformance = ModelCatalogOrdering.performance(for: mlxINT8)
        let cpuPerformance = ModelCatalogOrdering.performance(for: cpu)
        #expect(cpuPerformance.accuracy == 0.96)
        #expect(mlxPerformance.speed == 0.95)
        #expect(mlxPerformance.accuracy == 0.96)

        let paraformer = try #require(models.first { $0.name == "paraformer-large-zh" })
        let qwenOrder = ModelCatalogOrdering.localModelsByPerformance([mlxFP16, paraformer, mlxINT8])
        #expect(qwenOrder.map(\.name) == [mlxINT8.name, mlxFP16.name, paraformer.name])
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
