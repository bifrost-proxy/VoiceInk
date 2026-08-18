import Foundation

struct DoubaoSpeechProvider: CloudProvider {
    static let defaultResourceID = "volc.seedasr.sauc.duration"

    let modelProvider: ModelProvider = .doubaoSpeech
    let providerKey = "Doubao Speech"
    let isStreamingOnly = true
    let languageCodes: [String]? = ["auto"]
    let includesAutoDetect = true
    private let replayTranscriber: any DoubaoReplayTranscribing

    init(replayTranscriber: any DoubaoReplayTranscribing = DoubaoWebSocketReplayTranscriber()) {
        self.replayTranscriber = replayTranscriber
    }

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

    func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String]
    ) async throws -> String {
        try await transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language,
            customVocabulary: customVocabulary,
            recognitionContext: nil
        )
    }

    func transcribe(
        audioData: Data,
        fileName _: String,
        apiKey: String,
        model: String,
        language _: String?,
        customVocabulary: [String],
        recognitionContext: RecognitionContextEnvelope?
    ) async throws -> String {
        try await replayTranscriber.transcribe(
            wavData: audioData,
            apiKey: apiKey,
            resourceID: model,
            customVocabulary: customVocabulary,
            settings: .current(),
            recognitionContext: recognitionContext
        )
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
