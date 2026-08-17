import Foundation

enum DoubaoStreamingProtocolError: LocalizedError, Equatable {
    case invalidFrame(String)
    case unsupportedCompression(UInt8)
    case server(code: UInt32, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame(let message):
            return String(format: String(localized: "Invalid Doubao streaming response: %@"), message)
        case .unsupportedCompression(let compression):
            return String(
                format: String(localized: "Unsupported Doubao response compression: %lld"),
                Int64(compression)
            )
        case .server(let code, let message):
            return String(
                format: String(localized: "Doubao streaming error %lld: %@"),
                Int64(code),
                message
            )
        }
    }
}

struct DoubaoServerResponse: Equatable {
    let text: String
    let stableText: String
    let isFinal: Bool
}

/// Sends the first 100 ms promptly, then aggregates recorder callbacks into
/// the 200 ms PCM packets recommended by Doubao for bidirectional streaming
/// (16 kHz, mono, signed 16-bit PCM).
struct DoubaoAudioPacketizer {
    static let firstPacketByteCount = 16_000 * MemoryLayout<Int16>.size / 10
    static let packetByteCount = 16_000 * MemoryLayout<Int16>.size / 5

    private var pendingAudio = Data()
    private var sentFirstPacket = false

    mutating func append(_ data: Data) -> [Data] {
        pendingAudio.append(data)
        var packets: [Data] = []
        var targetByteCount = sentFirstPacket ? Self.packetByteCount : Self.firstPacketByteCount
        while pendingAudio.count >= targetByteCount {
            packets.append(Data(pendingAudio.prefix(targetByteCount)))
            pendingAudio.removeFirst(targetByteCount)
            sentFirstPacket = true
            targetByteCount = Self.packetByteCount
        }
        return packets
    }

    mutating func flush() -> Data? {
        guard !pendingAudio.isEmpty else { return nil }
        let remainder = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)
        return remainder
    }

    mutating func reset() {
        pendingAudio.removeAll(keepingCapacity: true)
        sentFirstPacket = false
    }
}

enum DoubaoStreamingProtocol {
    private static let versionAndHeaderSize: UInt8 = 0x11
    private static let fullClientRequest: UInt8 = 0x10
    private static let audioOnlyRequest: UInt8 = 0x20
    private static let finalAudioOnlyRequest: UInt8 = 0x22
    private static let jsonWithoutCompression: UInt8 = 0x10
    private static let rawWithoutCompression: UInt8 = 0x00

    static func makeFullClientRequest(
        customVocabulary: [String] = [],
        settings: DoubaoSpeechSettings = .defaults
    ) throws -> Data {
        // Domain function calls are documented only for the optimized
        // bidirectional stream when second-pass recognition is enabled.
        let enablePOIFunctionCall = settings.enableTwoPassRecognition && settings.enablePOIFunctionCall
        let enableMusicFunctionCall = settings.enableTwoPassRecognition && settings.enableMusicFunctionCall
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_nonstream": settings.enableTwoPassRecognition,
            "enable_itn": settings.enableTextNormalization,
            "enable_punc": settings.enablePunctuation,
            "enable_ddc": settings.enableSemanticSmoothing,
            "enable_accelerate_text": settings.enableFirstTextAcceleration,
            "show_utterances": true,
            "result_type": "full",
            "end_window_size": settings.silenceFinalizationMilliseconds,
        ]

        if settings.enableFirstTextAcceleration {
            request["accelerate_score"] = settings.firstTextAccelerationLevel
        }
        if enablePOIFunctionCall {
            request["enable_poi_fc"] = true
        }
        if enableMusicFunctionCall {
            request["enable_music_fc"] = true
        }

        let vocabulary = customVocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(50)

        var context: [String: Any] = [:]
        if !vocabulary.isEmpty {
            context["hotwords"] = vocabulary.map { ["word": $0] }
        }
        if enablePOIFunctionCall, !settings.poiCityName.isEmpty {
            context["loc_info"] = ["city_name": settings.poiCityName]
        }
        if !context.isEmpty {
            let contextData = try JSONSerialization.data(withJSONObject: context)
            guard let context = String(data: contextData, encoding: .utf8) else {
                throw DoubaoStreamingProtocolError.invalidFrame("Could not encode recognition context")
            }
            request["corpus"] = ["context": context]
        }

        let payload: [String: Any] = [
            "user": [
                // A new opaque identifier is used for each session; VoiceInk never transmits a hardware identifier.
                "uid": "voiceink-\(UUID().uuidString)",
                "platform": "macOS",
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16_000,
                "bits": 16,
                "channel": 1,
            ],
            "request": request,
        ]

        let json = try JSONSerialization.data(withJSONObject: payload)
        return makeFrame(
            messageTypeAndFlags: fullClientRequest,
            serializationAndCompression: jsonWithoutCompression,
            payload: json
        )
    }

    static func makeAudioRequest(_ audio: Data, isFinal: Bool) -> Data {
        makeFrame(
            messageTypeAndFlags: isFinal ? finalAudioOnlyRequest : audioOnlyRequest,
            serializationAndCompression: rawWithoutCompression,
            payload: audio
        )
    }

    static func parseServerMessage(_ message: URLSessionWebSocketTask.Message) throws -> DoubaoServerResponse? {
        switch message {
        case .data(let data):
            return try parseServerFrame(data)
        case .string(let text):
            throw DoubaoStreamingProtocolError.invalidFrame(text)
        @unknown default:
            throw DoubaoStreamingProtocolError.invalidFrame("Unsupported WebSocket message")
        }
    }

    static func parseServerFrame(_ data: Data) throws -> DoubaoServerResponse? {
        guard data.count >= 4 else {
            throw DoubaoStreamingProtocolError.invalidFrame("Header is shorter than four bytes")
        }

        let bytes = [UInt8](data)
        guard bytes[0] >> 4 == 1 else {
            throw DoubaoStreamingProtocolError.invalidFrame("Unsupported protocol version")
        }

        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard headerSize >= 4, bytes.count >= headerSize else {
            throw DoubaoStreamingProtocolError.invalidFrame("Invalid header size")
        }

        let messageType = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F
        guard compression == 0 else {
            throw DoubaoStreamingProtocolError.unsupportedCompression(compression)
        }

        switch messageType {
        case 0x09:
            var offset = headerSize
            if flags & 0x01 == 0x01 {
                try requireBytes(4, at: offset, in: bytes)
                offset += 4
            }

            let payloadSize = Int(try readUInt32(from: bytes, at: offset))
            offset += 4
            try requireBytes(payloadSize, at: offset, in: bytes)
            let payload = Data(bytes[offset..<(offset + payloadSize)])
            let json = try JSONSerialization.jsonObject(with: payload)
            guard let root = json as? [String: Any] else {
                throw DoubaoStreamingProtocolError.invalidFrame("Response payload is not a JSON object")
            }

            let result = root["result"] as? [String: Any]
            let text = result?["text"] as? String ?? ""
            let utterances = result?["utterances"] as? [[String: Any]] ?? []
            let stableText = utterances.compactMap { utterance -> String? in
                guard utterance["definite"] as? Bool == true else { return nil }
                return utterance["text"] as? String
            }.joined()

            return DoubaoServerResponse(
                text: text,
                stableText: stableText,
                isFinal: flags == 0x03
            )

        case 0x0F:
            var offset = headerSize
            let code = try readUInt32(from: bytes, at: offset)
            offset += 4
            let messageSize = Int(try readUInt32(from: bytes, at: offset))
            offset += 4
            try requireBytes(messageSize, at: offset, in: bytes)
            let message = String(bytes: bytes[offset..<(offset + messageSize)], encoding: .utf8)
                ?? String(localized: "Unknown server error")
            throw DoubaoStreamingProtocolError.server(code: code, message: message)

        default:
            return nil
        }
    }

    private static func makeFrame(
        messageTypeAndFlags: UInt8,
        serializationAndCompression: UInt8,
        payload: Data
    ) -> Data {
        var frame = Data([
            versionAndHeaderSize,
            messageTypeAndFlags,
            serializationAndCompression,
            0x00,
        ])
        appendUInt32(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return frame
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readUInt32(from bytes: [UInt8], at offset: Int) throws -> UInt32 {
        try requireBytes(4, at: offset, in: bytes)
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func requireBytes(_ count: Int, at offset: Int, in bytes: [UInt8]) throws {
        guard count >= 0, offset >= 0, offset <= bytes.count, count <= bytes.count - offset else {
            throw DoubaoStreamingProtocolError.invalidFrame("Frame payload is truncated")
        }
    }
}

final class DoubaoStreamingProvider: StreamingTranscriptionProvider {
    private let customVocabulary: [String]
    private let session: DoubaoWebSocketSession
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(customVocabulary: [String]) {
        self.customVocabulary = customVocabulary
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
        session = DoubaoWebSocketSession(eventsContinuation: continuation)
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language _: String?) async throws {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Doubao Speech"), !apiKey.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        try await session.connect(
            apiKey: apiKey,
            resourceID: model.name,
            customVocabulary: customHotwordTerms(),
            settings: DoubaoSpeechSettings.current(),
            endpoint: .optimizedStreaming,
            startReceiving: true
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

    /// Builds the inline hotword context accepted by Doubao. Vocabulary
    /// entries are sent as `hotwords[].word`.
    func customHotwordTerms() -> [String] {
        customVocabulary
    }
}

actor DoubaoWebSocketSession {
    enum Endpoint: Equatable {
        case optimizedStreaming
        case verification

        var url: URL {
            switch self {
            case .optimizedStreaming:
                return URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
            case .verification:
                return URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!
            }
        }
    }

    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var connection: (any CloudSpeechWebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var verificationTimedOut = false
    private var audioPacketizer = DoubaoAudioPacketizer()
    private var preconnectionTarget: CloudSpeechConnectionTarget?

    init(eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?) {
        self.eventsContinuation = eventsContinuation
    }

    static func verify(apiKey: String, resourceID: String) async throws {
        let session = DoubaoWebSocketSession(eventsContinuation: nil)
        try await session.connect(
            apiKey: apiKey,
            resourceID: resourceID,
            customVocabulary: [],
            settings: .defaults,
            endpoint: .verification,
            startReceiving: false
        )

        do {
            // A valid connection does not produce a recognition result until the
            // client sends an audio packet. An empty final packet is sufficient
            // to make the service validate the credentials and resource ID.
            try await session.commit()
            try await session.receiveVerificationResponse()
            await session.disconnect()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    func connect(
        apiKey: String,
        resourceID: String,
        customVocabulary: [String],
        settings: DoubaoSpeechSettings,
        endpoint: Endpoint,
        startReceiving: Bool
    ) async throws {
        guard connection == nil else { return }
        audioPacketizer.reset()

        let target = CloudSpeechConnectionTarget.doubao(
            apiKey: apiKey,
            resourceID: resourceID,
            endpoint: endpoint.url
        )

        do {
            var standbyConnection: (any CloudSpeechWebSocketConnection)?
            if endpoint == .optimizedStreaming {
                standbyConnection = await CloudSpeechConnectionPool.shared.lease(for: target)
                connection = standbyConnection
            }
            if connection == nil {
                connection = try await URLSessionCloudSpeechWebSocketConnector().open(
                    target: target,
                    onClosed: nil
                )
            }
            guard let connection else { throw StreamingTranscriptionError.notConnected }
            let initialRequest = try DoubaoStreamingProtocol.makeFullClientRequest(
                customVocabulary: customVocabulary,
                settings: settings
            )
            do {
                try await connection.send(.data(initialRequest))
            } catch where standbyConnection != nil {
                connection.close()
                self.connection = try await URLSessionCloudSpeechWebSocketConnector().open(
                    target: target,
                    onClosed: nil
                )
                guard let freshConnection = self.connection else {
                    throw StreamingTranscriptionError.notConnected
                }
                try await freshConnection.send(.data(initialRequest))
            }
            if endpoint == .optimizedStreaming {
                preconnectionTarget = target
            }
        } catch {
            closeSocket()
            throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
        }

        eventsContinuation?.yield(.sessionStarted)
        if startReceiving {
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let connection else { throw StreamingTranscriptionError.notConnected }
        for packet in audioPacketizer.append(data) {
            try await connection.send(.data(DoubaoStreamingProtocol.makeAudioRequest(packet, isFinal: false)))
        }
    }

    func commit() async throws {
        guard let connection else { throw StreamingTranscriptionError.notConnected }
        if let remainder = audioPacketizer.flush() {
            try await connection.send(.data(DoubaoStreamingProtocol.makeAudioRequest(remainder, isFinal: false)))
        }
        try await connection.send(.data(DoubaoStreamingProtocol.makeAudioRequest(Data(), isFinal: true)))
    }

    func disconnect() async {
        let completedTarget = preconnectionTarget
        preconnectionTarget = nil
        receiveTask?.cancel()
        receiveTask = nil
        closeSocket()
        if let completedTarget {
            await CloudSpeechConnectionPool.shared.recordUseCompleted(for: completedTarget)
        }
    }

    private func receiveVerificationResponse() async throws {
        guard let connection else { throw StreamingTranscriptionError.notConnected }
        verificationTimedOut = false
        let timeoutTask = Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.cancelForVerificationTimeout()
        }
        defer { timeoutTask.cancel() }

        do {
            let message = try await connection.receive()
            _ = try DoubaoStreamingProtocol.parseServerMessage(message)
        } catch {
            if verificationTimedOut {
                throw StreamingTranscriptionError.timeout
            }
            throw error
        }
    }

    private func cancelForVerificationTimeout() {
        verificationTimedOut = true
        connection?.close()
    }

    private func receiveLoop() async {
        guard let connection else { return }

        do {
            while !Task.isCancelled {
                let message = try await connection.receive()
                guard let response = try DoubaoStreamingProtocol.parseServerMessage(message) else { continue }
                if response.isFinal {
                    eventsContinuation?.yield(.committed(text: response.text))
                } else if !response.text.isEmpty {
                    eventsContinuation?.yield(.snapshot(text: response.text, stableText: response.stableText))
                }
            }
        } catch {
            if !Task.isCancelled {
                eventsContinuation?.yield(.error(error))
            }
        }
    }

    private func closeSocket() {
        audioPacketizer.reset()
        connection?.close()
        connection = nil
    }
}
