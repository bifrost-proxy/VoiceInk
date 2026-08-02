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
        let chineseCTC = try #require(models.first { $0.name == "parakeet-ctc-0.6b-zh-cn" })
        let englishOnly = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v2" })

        #expect(ModelLanguageSupportCatalog.supportsChinese(qwen))
        #expect(ModelLanguageSupportCatalog.supportsEnglish(qwen))
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
        #expect(
            ModelLanguageSupportCatalog.summary(for: chineseCTC) == [
                String(localized: "Chinese"),
                String(localized: "English"),
            ].joined(separator: " · ")
        )
    }
}
