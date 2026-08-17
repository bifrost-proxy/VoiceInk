import Foundation

enum AliyunQwenStreamingProtocolError: LocalizedError, Equatable {
    case invalidMessage(String)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let message):
            String(format: String(localized: "Invalid Alibaba Cloud ASR response: %@"), message)
        case .server(let code, let message):
            String(format: String(localized: "Alibaba Cloud ASR error %@: %@"), code, message)
        }
    }
}

struct AliyunQwenSentence: Equatable, Sendable {
    let id: Int
    let text: String
    let isFinal: Bool
    let isHeartbeat: Bool
}

enum AliyunQwenServerEvent: Equatable, Sendable {
    case taskStarted
    case result(AliyunQwenSentence)
    case taskFinished
    case taskFailed(code: String, message: String)
    case unknown(String)
}

enum AliyunQwenStreamingProtocol {
    static func makeRunTask(
        taskID: String,
        model: String,
        format: String,
        sampleRate: Int,
        language: String?,
        customVocabulary: [String],
        settings: AliyunQwenSpeechSettings
    ) throws -> String {
        var parameters: [String: Any] = [
            "format": format,
            "sample_rate": sampleRate,
            "semantic_punctuation_enabled": settings.semanticPunctuationEnabled,
            "max_sentence_silence": settings.maxSentenceSilenceMilliseconds,
            "multi_threshold_mode_enabled": settings.multiThresholdModeEnabled,
            "heartbeat": settings.heartbeatEnabled,
        ]

        if let language = normalizedLanguage(language) {
            parameters["language_hints"] = [language]
        }
        if settings.speechNoiseThresholdEnabled {
            parameters["speech_noise_threshold"] = settings.speechNoiseThreshold
        }

        let vocabulary = normalizedVocabulary(customVocabulary, settings: settings)
        if !vocabulary.isEmpty {
            parameters["vocabulary"] = vocabulary
        }

        var input: [String: Any] = [:]
        let contextPrompt = settings.contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contextPrompt.isEmpty {
            input["context"] = [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": String(contextPrompt.prefix(AliyunQwenSpeechSettings.maximumContextLength)),
                        ]
                    ],
                ]
            ]
        }

        let request: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": input,
            ],
        ]
        return try encode(request)
    }

    static func makeFinishTask(taskID: String) throws -> String {
        try encode([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": ["input": [:] as [String: Any]],
        ])
    }

    static func parseServerMessage(_ message: URLSessionWebSocketTask.Message) throws -> AliyunQwenServerEvent {
        guard case .string(let text) = message else {
            throw AliyunQwenStreamingProtocolError.invalidMessage("Expected a JSON text frame")
        }
        guard
            let data = text.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let header = root["header"] as? [String: Any],
            let event = header["event"] as? String
        else {
            throw AliyunQwenStreamingProtocolError.invalidMessage("Missing event header")
        }

        switch event {
        case "task-started":
            return .taskStarted
        case "result-generated":
            guard
                let payload = root["payload"] as? [String: Any],
                let output = payload["output"] as? [String: Any],
                let sentence = output["sentence"] as? [String: Any]
            else {
                throw AliyunQwenStreamingProtocolError.invalidMessage("Missing recognition sentence")
            }
            return .result(
                AliyunQwenSentence(
                    id: sentence["sentence_id"] as? Int ?? 0,
                    text: sentence["text"] as? String ?? "",
                    isFinal: sentence["sentence_end"] as? Bool ?? false,
                    isHeartbeat: sentence["heartbeat"] as? Bool ?? false
                )
            )
        case "task-finished":
            return .taskFinished
        case "task-failed":
            return .taskFailed(
                code: header["error_code"] as? String ?? "UNKNOWN",
                message: header["error_message"] as? String ?? String(localized: "Unknown server error")
            )
        default:
            return .unknown(event)
        }
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != "auto", AliyunQwenSpeechProvider.supportedLanguageCodes.contains(normalized) else {
            return nil
        }
        return normalized
    }

    private static func normalizedVocabulary(
        _ terms: [String],
        settings: AliyunQwenSpeechSettings
    ) -> [String: Int] {
        guard settings.useVoiceInkVocabulary else { return [:] }
        var result: [String: Int] = [:]
        for term in terms {
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, result[normalized] == nil else { continue }
            result[normalized] = settings.vocabularyWeight
            if result.count == 2_000 { break }
        }
        return result
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AliyunQwenStreamingProtocolError.invalidMessage("Could not encode request")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw AliyunQwenStreamingProtocolError.invalidMessage("Could not encode request as UTF-8")
        }
        return text
    }
}

final class AliyunQwenStreamingProvider: StreamingTranscriptionProvider {
    private let customVocabulary: [String]
    private let session: AliyunQwenWebSocketSession
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(customVocabulary: [String]) {
        self.customVocabulary = customVocabulary
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
        session = AliyunQwenWebSocketSession(eventsContinuation: continuation)
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard
            let apiKey = APIKeyManager.shared.getAPIKey(forProvider: AliyunQwenSpeechProvider.key),
            !apiKey.isEmpty
        else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        try await session.connect(
            apiKey: apiKey,
            model: model.name,
            language: language,
            customVocabulary: customHotwordTerms(),
            settings: .current(),
            format: "pcm"
        )
    }

    func sendAudioChunk(_ data: Data) async throws {
        try await session.sendAudioChunk(data)
    }

    func commit() async throws {
        try await session.commit()
    }

    func disconnect() async {
        await session.disconnect()
        eventsContinuation?.finish()
    }

    func customHotwordTerms() -> [String] {
        customVocabulary
    }
}

actor AliyunQwenWebSocketSession {
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var connection: (any CloudSpeechWebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var taskID: String?
    private var pendingAudio = Data()
    private var committedSentences: [Int: String] = [:]
    private var didFinish = false
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var startTimedOut = false
    private var finishTimeoutTask: Task<Void, Never>?
    private var preconnectionTarget: CloudSpeechConnectionTarget?

    init(eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?) {
        self.eventsContinuation = eventsContinuation
    }

    static func verify(apiKey: String, model: String, settings: AliyunQwenSpeechSettings) async throws {
        let session = AliyunQwenWebSocketSession(eventsContinuation: nil)
        do {
            try await session.connect(
                apiKey: apiKey,
                model: model,
                language: nil,
                customVocabulary: [],
                settings: settings,
                format: "pcm"
            )
            await session.disconnect()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    func connect(
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String],
        settings: AliyunQwenSpeechSettings,
        format: String
    ) async throws {
        guard connection == nil else { return }

        let endpoint = try settings.webSocketURL()
        let target = CloudSpeechConnectionTarget.aliyun(apiKey: apiKey, endpoint: endpoint)
        let taskID = UUID().uuidString
        self.taskID = taskID

        do {
            let standbyConnection = await CloudSpeechConnectionPool.shared.lease(for: target)
            connection = standbyConnection
            if connection == nil {
                connection = try await URLSessionCloudSpeechWebSocketConnector().open(
                    target: target,
                    onClosed: nil
                )
            }
            guard let connection else { throw StreamingTranscriptionError.notConnected }
            let runTask = try AliyunQwenStreamingProtocol.makeRunTask(
                taskID: taskID,
                model: model,
                format: format,
                sampleRate: 16_000,
                language: language,
                customVocabulary: customVocabulary,
                settings: settings
            )
            do {
                try await connection.send(.string(runTask))
            } catch where standbyConnection != nil {
                connection.close()
                self.connection = try await URLSessionCloudSpeechWebSocketConnector().open(
                    target: target,
                    onClosed: nil
                )
                guard let freshConnection = self.connection else {
                    throw StreamingTranscriptionError.notConnected
                }
                try await freshConnection.send(.string(runTask))
            }
            try await receiveTaskStarted()
            preconnectionTarget = target
        } catch {
            closeSocket()
            if error is AliyunQwenStreamingProtocolError || error is AliyunQwenSettingsError {
                throw error
            }
            throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
        }

        eventsContinuation?.yield(.sessionStarted)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard connection != nil else { throw StreamingTranscriptionError.notConnected }
        pendingAudio.append(data)
        while pendingAudio.count >= 3_200 {
            let chunk = pendingAudio.prefix(3_200)
            pendingAudio.removeFirst(3_200)
            try await sendBinary(Data(chunk))
        }
    }

    func commit() async throws {
        guard let connection, let taskID else { throw StreamingTranscriptionError.notConnected }
        if !pendingAudio.isEmpty {
            let remainder = pendingAudio
            pendingAudio.removeAll(keepingCapacity: true)
            try await sendBinary(remainder)
        }

        let finishTask = try AliyunQwenStreamingProtocol.makeFinishTask(taskID: taskID)
        try await connection.send(.string(finishTask))
        try await waitForTaskFinished()
        eventsContinuation?.yield(.committed(text: ""))
    }

    func finalTranscript() -> String {
        committedSentences.keys.sorted().compactMap { committedSentences[$0] }.joined(separator: " ")
    }

    func disconnect() async {
        let completedTarget = preconnectionTarget
        preconnectionTarget = nil
        receiveTask?.cancel()
        receiveTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishContinuation?.resume(throwing: StreamingTranscriptionError.notConnected)
        finishContinuation = nil
        closeSocket()
        if let completedTarget {
            await CloudSpeechConnectionPool.shared.recordUseCompleted(for: completedTarget)
        }
    }

    private func receiveTaskStarted() async throws {
        guard let connection else { throw StreamingTranscriptionError.notConnected }
        startTimedOut = false
        let timeoutTask = Task<Void, Never> { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.cancelForStartTimeout()
        }
        defer { timeoutTask.cancel() }

        do {
            while true {
                let message = try await connection.receive()
                switch try AliyunQwenStreamingProtocol.parseServerMessage(message) {
                case .taskStarted:
                    return
                case .taskFailed(let code, let message):
                    throw AliyunQwenStreamingProtocolError.server(code: code, message: message)
                default:
                    continue
                }
            }
        } catch {
            if startTimedOut { throw StreamingTranscriptionError.timeout }
            throw error
        }
    }

    private func receiveLoop() async {
        guard let connection else { return }
        do {
            while !Task.isCancelled {
                let message = try await connection.receive()
                switch try AliyunQwenStreamingProtocol.parseServerMessage(message) {
                case .result(let sentence):
                    guard !sentence.isHeartbeat else { continue }
                    if sentence.isFinal {
                        guard committedSentences[sentence.id] == nil else { continue }
                        committedSentences[sentence.id] = sentence.text
                        if !sentence.text.isEmpty {
                            eventsContinuation?.yield(.committed(text: sentence.text))
                        }
                    } else if !sentence.text.isEmpty {
                        eventsContinuation?.yield(.partial(text: sentence.text))
                    }
                case .taskFinished:
                    didFinish = true
                    finishTimeoutTask?.cancel()
                    finishTimeoutTask = nil
                    finishContinuation?.resume()
                    finishContinuation = nil
                    return
                case .taskFailed(let code, let message):
                    let error = AliyunQwenStreamingProtocolError.server(code: code, message: message)
                    finishTimeoutTask?.cancel()
                    finishTimeoutTask = nil
                    finishContinuation?.resume(throwing: error)
                    finishContinuation = nil
                    eventsContinuation?.yield(.error(error))
                    return
                default:
                    continue
                }
            }
        } catch {
            guard !Task.isCancelled, !didFinish else { return }
            finishTimeoutTask?.cancel()
            finishTimeoutTask = nil
            finishContinuation?.resume(throwing: error)
            finishContinuation = nil
            eventsContinuation?.yield(.error(error))
        }
    }

    private func waitForTaskFinished() async throws {
        if didFinish { return }
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.failFinishForTimeout()
            }
        }
    }

    private func sendBinary(_ data: Data) async throws {
        guard let connection else { throw StreamingTranscriptionError.notConnected }
        try await connection.send(.data(data))
    }

    private func cancelForStartTimeout() {
        startTimedOut = true
        connection?.close()
    }

    private func failFinishForTimeout() {
        guard let finishContinuation else { return }
        self.finishContinuation = nil
        finishTimeoutTask = nil
        finishContinuation.resume(throwing: StreamingTranscriptionError.timeout)
    }

    private func closeSocket() {
        connection?.close()
        connection = nil
        taskID = nil
    }
}
