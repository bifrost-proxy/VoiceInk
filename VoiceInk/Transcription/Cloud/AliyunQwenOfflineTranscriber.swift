import Foundation

enum AliyunQwenOfflineError: LocalizedError {
    case requestTooLarge
    case invalidResponse
    case server(statusCode: Int, message: String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .requestTooLarge:
            "The recording is too large for fast Alibaba Cloud offline transcription."
        case .invalidResponse:
            "Alibaba Cloud returned an invalid offline transcription response."
        case .server(let statusCode, let message):
            "Alibaba Cloud offline transcription failed (\(statusCode)): \(message)"
        case .emptyTranscript:
            "Alibaba Cloud offline transcription returned no text."
        }
    }
}

struct AliyunQwenOfflineTranscriber: Sendable {
    static let modelID = "qwen-audio-3.0-asr-flash"
    /// The API accepts a request body of roughly 10 MB. Leave room for JSON,
    /// vocabulary, and context rather than relying on audio duration alone.
    static let maximumBase64AudioBytes = 9_500_000

    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func supportsFastRequest(audioData: Data) -> Bool {
        ((audioData.count + 2) / 3) * 4 <= Self.maximumBase64AudioBytes
    }

    func transcribe(
        audioData: Data,
        apiKey: String,
        language: String?,
        customVocabulary: [String],
        settings: AliyunQwenSpeechSettings,
        recognitionContext: String? = nil
    ) async throws -> String {
        guard supportsFastRequest(audioData: audioData) else {
            throw AliyunQwenOfflineError.requestTooLarge
        }

        var messages: [[String: Any]] = []
        let context = [settings.contextPrompt, recognitionContext ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
        if !context.isEmpty {
            messages.append([
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": String(context.prefix(AliyunQwenSpeechSettings.maximumContextLength)),
                ]],
            ])
        }
        messages.append([
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": [
                    "data": "data:audio/wav;base64,\(audioData.base64EncodedString())"
                ],
            ]],
        ])

        var parameters: [String: Any] = [
            "format": "wav",
            "sample_rate": 16_000,
        ]
        if let language = normalizedLanguage(language) {
            parameters["language_hints"] = [language]
        }
        if settings.useVoiceInkVocabulary {
            let terms = normalizedVocabulary(customVocabulary)
            if !terms.isEmpty {
                parameters["vocabulary"] = terms.map {
                    ["text": $0, "weight": settings.vocabularyWeight]
                }
            }
        }

        let body: [String: Any] = [
            "model": Self.modelID,
            "input": ["messages": messages],
            "parameters": parameters,
        ]
        var request = URLRequest(url: try settings.offlineTranscriptionURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunQwenOfflineError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw AliyunQwenOfflineError.server(statusCode: httpResponse.statusCode, message: message)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let output = root["output"] as? [String: Any]
        else {
            throw AliyunQwenOfflineError.invalidResponse
        }

        let directText = output["text"] as? String
        let choiceText = ((output["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            .flatMap { $0["content"] as? [[String: Any]] }?.first?["text"] as? String
        let text = (directText ?? choiceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AliyunQwenOfflineError.emptyTranscript }
        return text
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "auto" ? nil : normalized
    }

    private func normalizedVocabulary(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}
