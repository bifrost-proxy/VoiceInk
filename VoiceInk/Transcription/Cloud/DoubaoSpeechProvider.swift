import Foundation

struct DoubaoSpeechProvider: CloudProvider {
    static let defaultResourceID = "volc.seedasr.sauc.duration"

    let modelProvider: ModelProvider = .doubaoSpeech
    let providerKey = "Doubao Speech"
    let isStreamingOnly = true
    let languageCodes: [String]? = ["auto"]
    let includesAutoDetect = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: Self.defaultResourceID,
                displayName: "Doubao Streaming ASR 2.0",
                description: "Optimized bidirectional streaming recognition with a high-accuracy second pass",
                provider: .doubaoSpeech,
                speed: 0.98,
                accuracy: 0.96,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true,
                    provider: .doubaoSpeech
                )
            ),
            CloudModel(
                name: "volc.seedasr.sauc.concurrent",
                displayName: "Doubao Streaming ASR 2.0 (Concurrent)",
                description: "Concurrent-billing resource for the optimized bidirectional streaming model",
                provider: .doubaoSpeech,
                speed: 0.98,
                accuracy: 0.96,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true,
                    provider: .doubaoSpeech
                )
            ),
        ]
    }

    func makeStreamingProvider(customVocabulary: [String]) -> (any StreamingTranscriptionProvider)? {
        DoubaoStreamingProvider(customVocabulary: customVocabulary)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        do {
            try await DoubaoWebSocketSession.verify(
                apiKey: key,
                resourceID: Self.defaultResourceID
            )
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
