import Foundation

struct AliyunQwenSpeechProvider: CloudProvider {
    static let modelID = "qwen-audio-3.0-asr-flash-streaming"
    static let key = "Alibaba Cloud Qwen"
    static let supportedLanguageCodes = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "tl", "hi",
        "ar", "fr", "de", "es", "pt", "ru", "it", "nl", "sv", "da",
        "fi", "no", "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk",
    ]

    let modelProvider: ModelProvider = .aliyunQwen
    let providerKey = Self.key
    let languageCodes: [String]? = Self.supportedLanguageCodes
    let includesAutoDetect = true
    let isStreamingOnly = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: Self.modelID,
                displayName: "Qwen Audio 3.0 ASR Flash Streaming",
                description: "Native streaming recognition with multilingual, dialect, hotword, and context support",
                provider: .aliyunQwen,
                speed: 0.98,
                accuracy: 0.97,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(
                    isMultilingual: true,
                    provider: .aliyunQwen
                )
            )
        ]
    }

    func makeStreamingProvider(customVocabulary: [String]) -> (any StreamingTranscriptionProvider)? {
        AliyunQwenStreamingProvider(customVocabulary: customVocabulary)
    }

    func transcribe(
        audioData: Data,
        fileName _: String,
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String]
    ) async throws -> String {
        let settings = AliyunQwenSpeechSettings.current()
        let session = AliyunQwenWebSocketSession(eventsContinuation: nil)

        do {
            try await session.connect(
                apiKey: apiKey,
                model: model,
                language: language,
                customVocabulary: customVocabulary,
                settings: settings,
                format: "wav"
            )

            for offset in stride(from: 0, to: audioData.count, by: 3_200) {
                let end = min(offset + 3_200, audioData.count)
                try await session.sendAudioChunk(audioData.subdata(in: offset..<end))
                try await Task.sleep(for: .milliseconds(100))
            }

            try await session.commit()
            let transcript = await session.finalTranscript()
            await session.disconnect()
            return transcript
        } catch {
            await session.disconnect()
            throw error
        }
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        do {
            try await AliyunQwenWebSocketSession.verify(
                apiKey: key,
                model: Self.modelID,
                settings: .current()
            )
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
