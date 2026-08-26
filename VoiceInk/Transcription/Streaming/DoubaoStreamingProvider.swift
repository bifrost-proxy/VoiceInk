import Foundation
import os

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

struct DoubaoServerResponse: Equatable, Sendable {
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

    var bufferedByteCount: Int { pendingAudio.count }

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
        settings: DoubaoSpeechSettings = .defaults,
        recognitionContext: RecognitionContextEnvelope? = nil
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
        if let dialogContext = DoubaoRecognitionContextSerializer.serialize(
            recognitionContext,
            fallbackScenario: settings.contextPrompt
        ).value,
            let data = dialogContext.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            context.merge(object) { _, dynamicValue in dynamicValue }
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
    private let recognitionContext: RecognitionContextEnvelope?
    private let session: DoubaoWebSocketSession
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(customVocabulary: [String], recognitionContext: RecognitionContextEnvelope? = nil) {
        self.customVocabulary = customVocabulary
        self.recognitionContext = recognitionContext
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
        session = DoubaoWebSocketSession(eventsContinuation: continuation)
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language _: String?) async throws {
        guard
            let apiKey = APIKeyManager.shared.getAPIKey(
                forProvider: "Doubao Speech",
                allowAuthenticationUI: true
            ),
            !apiKey.isEmpty
        else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        try await session.connect(
            apiKey: apiKey,
            resourceID: model.name,
            customVocabulary: customHotwordTerms(),
            settings: DoubaoSpeechSettings.current(),
            recognitionContext: recognitionContext,
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

    func observedConcurrentAttemptCount() async -> Int? {
        await session.observedConcurrentAttemptCount
    }

    /// Builds the inline hotword context accepted by Doubao. Vocabulary
    /// entries are sent as `hotwords[].word`.
    func customHotwordTerms() -> [String] {
        customVocabulary
    }
}

/// Serializes every live and full-file Doubao request in the process. Recording
/// capture can begin immediately, while opening the next socket waits until the
/// prior attempt has released ownership.
actor DoubaoAttemptCoordinator {
    static let shared = DoubaoAttemptCoordinator()

    private var activeAttemptID: UUID?
    private(set) var maximumObservedCount = 0

    func acquire(
        _ attemptID: UUID,
        timeout: Duration = StreamingAudioIntegrityPolicy.startupTimeout
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while let activeAttemptID, activeAttemptID != attemptID {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw StreamingTranscriptionError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        activeAttemptID = attemptID
        maximumObservedCount = max(maximumObservedCount, 1)
    }

    func release(_ attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
    }

    var activeCount: Int { activeAttemptID == nil ? 0 : 1 }
}

actor DoubaoWebSocketSession {
    private static let maxEarlyRecoveryAudioBytes = 2 * 1_024 * 1_024
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "DoubaoWebSocketSession"
    )
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
    private let connectionPool: CloudSpeechConnectionPool
    private let connector: any CloudSpeechWebSocketConnecting
    private let attemptCoordinator: DoubaoAttemptCoordinator
    private let attemptID = UUID()
    private var connection: (any CloudSpeechWebSocketConnection)?
    private var ownsAttempt = false
    private(set) var observedConcurrentAttemptCount: Int?
    private var receiveTask: Task<Void, Never>?
    private var verificationTimedOut = false
    private var finalResultTimedOut = false
    private var finalResultCancelled = false
    private var finalResultTimeoutTask: Task<Void, Never>?
    private var audioPacketizer = DoubaoAudioPacketizer()
    private var preconnectionTarget: CloudSpeechConnectionTarget?
    private var sessionGeneration = UUID()
    private var earlyRecoveryTarget: CloudSpeechConnectionTarget?
    private var earlyRecoveryInitialRequest: Data?
    private var earlyRecoveryAudio = Data()
    private var earlyRecoveryIsEligible = false
    private var earlyRecoveryWasAttempted = false
    private var earlyRecoveryBufferOverflowed = false
    private var earlyRecoveryCommitRequested = false
    private var isRecoveringEarly = false
    private var earlyRecoveryWaiters: [CheckedContinuation<Bool, Never>] = []

    init(
        eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?,
        connectionPool: CloudSpeechConnectionPool = .shared,
        connector: any CloudSpeechWebSocketConnecting = URLSessionCloudSpeechWebSocketConnector(),
        attemptCoordinator: DoubaoAttemptCoordinator = .shared
    ) {
        self.eventsContinuation = eventsContinuation
        self.connectionPool = connectionPool
        self.connector = connector
        self.attemptCoordinator = attemptCoordinator
    }

    static func verify(
        apiKey: String,
        resourceID: String,
        customVocabulary: [String] = [],
        settings: DoubaoSpeechSettings = .defaults,
        recognitionContext: RecognitionContextEnvelope? = nil
    ) async throws {
        let session = DoubaoWebSocketSession(eventsContinuation: nil)
        try await session.connect(
            apiKey: apiKey,
            resourceID: resourceID,
            customVocabulary: customVocabulary,
            settings: settings,
            recognitionContext: recognitionContext,
            endpoint: .verification,
            startReceiving: false,
            coordinateAttempt: false
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

    static func verifyContextCombination(
        apiKey: String,
        resourceID: String,
        customVocabulary: [String],
        settings: DoubaoSpeechSettings,
        recognitionContext: RecognitionContextEnvelope
    ) async throws {
        let session = DoubaoWebSocketSession(eventsContinuation: nil)
        try await session.connect(
            apiKey: apiKey,
            resourceID: resourceID,
            customVocabulary: customVocabulary,
            settings: settings,
            recognitionContext: recognitionContext,
            endpoint: .optimizedStreaming,
            startReceiving: false,
            coordinateAttempt: false
        )
        do {
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
        recognitionContext: RecognitionContextEnvelope? = nil,
        endpoint: Endpoint,
        startReceiving: Bool,
        allowPreconnectedConnection: Bool = true,
        coordinateAttempt: Bool = true
    ) async throws {
        guard connection == nil else { return }
        if coordinateAttempt {
            try await attemptCoordinator.acquire(attemptID)
            ownsAttempt = true
            observedConcurrentAttemptCount = await attemptCoordinator.activeCount
        } else {
            observedConcurrentAttemptCount = nil
        }
        do {
            try Task.checkCancellation()
        } catch {
            await releaseAttemptOwnership()
            throw error
        }
        audioPacketizer.reset()
        resetEarlyRecoveryState()
        sessionGeneration = UUID()

        let target = CloudSpeechConnectionTarget.doubao(
            apiKey: apiKey,
            resourceID: resourceID,
            endpoint: endpoint.url
        )
        var connectionSource = "none"
        var connectionStage = "select"
        let connectStartedAt = Date()

        do {
            var standbyConnection: (any CloudSpeechWebSocketConnection)?
            if endpoint == .optimizedStreaming, allowPreconnectedConnection {
                connectionStage = "lease"
                standbyConnection = await connectionPool.lease(for: target)
                do {
                    try Task.checkCancellation()
                } catch {
                    standbyConnection?.close()
                    throw error
                }
                connection = standbyConnection
                if standbyConnection != nil {
                    connectionSource = "preconnected"
                    Self.logger.notice(
                        "Doubao connection selected source=preconnected \(target.key.diagnosticLabel, privacy: .public)"
                    )
                }
            }
            if connection == nil {
                connectionStage = "openFresh"
                connectionSource = "fresh"
                Self.logger.notice(
                    "Doubao connection opening source=fresh \(target.key.diagnosticLabel, privacy: .public)"
                )
                let freshConnection = try await connector.open(
                    target: target,
                    onClosed: nil
                )
                do {
                    try Task.checkCancellation()
                } catch {
                    freshConnection.close()
                    throw error
                }
                connection = freshConnection
                Self.logger.notice(
                    "Doubao connection opened source=fresh elapsed=\(Date().timeIntervalSince(connectStartedAt), format: .fixed(precision: 3), privacy: .public)s \(target.key.diagnosticLabel, privacy: .public)"
                )
            }
            guard let connection else { throw StreamingTranscriptionError.notConnected }
            try Task.checkCancellation()
            if let logID = connection.responseHeader(named: "X-Tt-Logid"), !logID.isEmpty {
                Self.logger.notice(
                    "Doubao recognition session opened source=\(connectionSource, privacy: .public) logID=\(logID, privacy: .public)"
                )
            }
            let initialRequest = try DoubaoStreamingProtocol.makeFullClientRequest(
                customVocabulary: customVocabulary,
                settings: settings,
                recognitionContext: recognitionContext
            )
            var shouldArmEarlyRecovery = standbyConnection != nil
            connectionStage = "sendInitialRequest"
            do {
                try await connection.send(.data(initialRequest))
            } catch let preconnectedError where standbyConnection != nil {
                shouldArmEarlyRecovery = false
                Self.logger.warning(
                    "Doubao preconnected socket rejected initial request; retrying source=fresh error=\(preconnectedError.localizedDescription, privacy: .public) \(target.key.diagnosticLabel, privacy: .public)"
                )
                connection.close()
                connectionStage = "openFreshRetry"
                let freshRetryStartedAt = Date()
                let freshConnection = try await connector.open(
                    target: target,
                    onClosed: nil
                )
                do {
                    try Task.checkCancellation()
                } catch {
                    freshConnection.close()
                    throw error
                }
                self.connection = freshConnection
                connectionSource = "freshRetry"
                Self.logger.notice(
                    "Doubao fresh retry connection opened elapsed=\(Date().timeIntervalSince(freshRetryStartedAt), format: .fixed(precision: 3), privacy: .public)s \(target.key.diagnosticLabel, privacy: .public)"
                )
                connectionStage = "sendInitialRequestFreshRetry"
                try await freshConnection.send(.data(initialRequest))
                Self.logger.notice(
                    "Doubao fresh retry initial request accepted \(target.key.diagnosticLabel, privacy: .public)"
                )
            }
            if shouldArmEarlyRecovery {
                earlyRecoveryTarget = target
                earlyRecoveryInitialRequest = initialRequest
                earlyRecoveryIsEligible = true
            }
            Self.logger.notice(
                "Doubao connection ready source=\(connectionSource, privacy: .public) elapsed=\(Date().timeIntervalSince(connectStartedAt), format: .fixed(precision: 3), privacy: .public)s \(target.key.diagnosticLabel, privacy: .public)"
            )
            if endpoint == .optimizedStreaming, allowPreconnectedConnection {
                preconnectionTarget = target
            }
        } catch {
            Self.logger.error(
                "Doubao connection failed stage=\(connectionStage, privacy: .public) source=\(connectionSource, privacy: .public) elapsed=\(Date().timeIntervalSince(connectStartedAt), format: .fixed(precision: 3), privacy: .public)s \(target.key.diagnosticLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            closeSocket()
            await releaseAttemptOwnership()
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
        if isRecoveringEarly {
            bufferAudioForEarlyRecovery(data)
            return
        }
        if earlyRecoveryIsEligible {
            bufferAudioForEarlyRecovery(data)
        }

        guard let sendingConnection = connection else { throw StreamingTranscriptionError.notConnected }
        do {
            for packet in audioPacketizer.append(data) {
                try await sendingConnection.send(
                    .data(DoubaoStreamingProtocol.makeAudioRequest(packet, isFinal: false))
                )
            }
        } catch {
            if await recoverEarlyIfNeeded(after: error, failedConnection: sendingConnection) {
                return
            }
            throw error
        }
    }

    func commit() async throws {
        if isRecoveringEarly {
            earlyRecoveryCommitRequested = true
            return
        }
        if earlyRecoveryIsEligible {
            earlyRecoveryCommitRequested = true
        }

        guard let sendingConnection = connection else { throw StreamingTranscriptionError.notConnected }
        do {
            if let remainder = audioPacketizer.flush() {
                try await sendingConnection.send(
                    .data(DoubaoStreamingProtocol.makeAudioRequest(remainder, isFinal: false))
                )
            }
            try await sendingConnection.send(
                .data(DoubaoStreamingProtocol.makeAudioRequest(Data(), isFinal: true))
            )
        } catch {
            if await recoverEarlyIfNeeded(after: error, failedConnection: sendingConnection) {
                return
            }
            throw error
        }
    }

    func disconnect() async {
        let completedTarget = preconnectionTarget
        preconnectionTarget = nil
        sessionGeneration = UUID()
        receiveTask?.cancel()
        receiveTask = nil
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = nil
        closeSocket()
        resetEarlyRecoveryState()
        if let completedTarget {
            await connectionPool.recordUseCompleted(for: completedTarget)
        }
        await releaseAttemptOwnership()
    }

    func receiveFinalTranscript(
        timeout: Duration? = .seconds(10),
        onSnapshot: (@Sendable (DoubaoServerResponse) -> Void)? = nil
    ) async throws -> String {
        guard let connection else { throw StreamingTranscriptionError.notConnected }
        var latestFullyStableTranscript: String?
        if let timeout {
            finalResultTimedOut = false
            finalResultCancelled = false
            finalResultTimeoutTask?.cancel()
            finalResultTimeoutTask = nil
            armFinalResultTimeout(after: timeout)
        } else if finalResultTimeoutTask == nil {
            // Replay starts its receiver before commit and arms the deadline
            // afterwards. If executor scheduling lets arming win, preserve that
            // task instead of cancelling it when the receiver first runs.
            finalResultTimedOut = false
            finalResultCancelled = false
        }
        defer {
            finalResultTimeoutTask?.cancel()
            finalResultTimeoutTask = nil
        }

        return try await withTaskCancellationHandler {
            do {
                while true {
                    try Task.checkCancellation()
                    let message = try await connection.receive()
                    guard let response = try DoubaoStreamingProtocol.parseServerMessage(message) else { continue }
                    if response.isFinal {
                        return response.text
                    }
                    if !response.text.isEmpty {
                        let preview = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let stable = response.stableText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !stable.isEmpty, stable == preview {
                            latestFullyStableTranscript = stable
                        }
                        onSnapshot?(response)
                    }
                }
            } catch {
                if finalResultCancelled { throw CancellationError() }
                if finalResultTimedOut {
                    if let latestFullyStableTranscript {
                        return latestFullyStableTranscript
                    }
                    throw StreamingTranscriptionError.timeout
                }
                if error is CancellationError { throw CancellationError() }
                throw error
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelForFinalResultCancellation()
            }
        }
    }

    func armFinalResultTimeout(after timeout: Duration) {
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = Task<Void, Never> { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.cancelForFinalResultTimeout()
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

    private func cancelForFinalResultTimeout() {
        finalResultTimedOut = true
        connection?.close()
    }

    private func cancelForFinalResultCancellation() {
        finalResultCancelled = true
        connection?.close()
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let receivingConnection = connection else { return }
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await receivingConnection.receive()
            } catch {
                if Task.isCancelled { return }
                if await recoverEarlyIfNeeded(after: error, failedConnection: receivingConnection) {
                    continue
                }
                eventsContinuation?.yield(.error(error))
                return
            }

            // Any server frame proves that the leased socket survived request
            // startup. Protocol and service errors must remain terminal rather
            // than being retried as stale-transport failures.
            markServerResponseReceived()
            do {
                guard let response = try DoubaoStreamingProtocol.parseServerMessage(message) else { continue }
                if response.isFinal {
                    eventsContinuation?.yield(.committed(text: response.text))
                    // The final frame completes the Doubao request. Do not wait
                    // for the server's normal WebSocket close and surface that
                    // close as a transport failure after a valid transcript.
                    return
                } else if !response.text.isEmpty {
                    eventsContinuation?.yield(.snapshot(text: response.text, stableText: response.stableText))
                }
            } catch {
                eventsContinuation?.yield(.error(error))
                return
            }
        }
    }

    private func recoverEarlyIfNeeded(
        after error: Error,
        failedConnection: any CloudSpeechWebSocketConnection
    ) async -> Bool {
        if let currentConnection = connection, currentConnection !== failedConnection {
            return true
        }
        if isRecoveringEarly {
            return await withCheckedContinuation { continuation in
                earlyRecoveryWaiters.append(continuation)
            }
        }
        guard earlyRecoveryIsEligible, !earlyRecoveryWasAttempted,
            let target = earlyRecoveryTarget,
            let initialRequest = earlyRecoveryInitialRequest
        else {
            return false
        }

        earlyRecoveryWasAttempted = true
        earlyRecoveryIsEligible = false
        isRecoveringEarly = true
        let generation = sessionGeneration
        let recoveryStartedAt = Date()
        connection = nil
        failedConnection.close()
        Self.logger.warning(
            "Doubao preconnected socket failed before first server response; recovering immediately source=fresh error=\(error.localizedDescription, privacy: .public) bufferedBytes=\(self.earlyRecoveryAudio.count, privacy: .public) \(target.key.diagnosticLabel, privacy: .public)"
        )

        var freshConnection: (any CloudSpeechWebSocketConnection)?
        do {
            freshConnection = try await connector.open(target: target, onClosed: nil)
            guard sessionGeneration == generation, !Task.isCancelled, let freshConnection else {
                throw CancellationError()
            }
            connection = freshConnection
            try await freshConnection.send(.data(initialRequest))
            guard !earlyRecoveryBufferOverflowed else {
                throw StreamingTranscriptionError.connectionFailed(
                    "Doubao early-recovery audio buffer exceeded \(Self.maxEarlyRecoveryAudioBytes) bytes"
                )
            }

            audioPacketizer.reset()
            while !earlyRecoveryAudio.isEmpty {
                let audio = earlyRecoveryAudio
                earlyRecoveryAudio.removeAll(keepingCapacity: true)
                for packet in audioPacketizer.append(audio) {
                    try await freshConnection.send(
                        .data(DoubaoStreamingProtocol.makeAudioRequest(packet, isFinal: false))
                    )
                }
                guard sessionGeneration == generation, !Task.isCancelled else {
                    throw CancellationError()
                }
                guard !earlyRecoveryBufferOverflowed else {
                    throw StreamingTranscriptionError.connectionFailed(
                        "Doubao early-recovery audio buffer exceeded \(Self.maxEarlyRecoveryAudioBytes) bytes"
                    )
                }
            }
            if earlyRecoveryCommitRequested {
                if let remainder = audioPacketizer.flush() {
                    try await freshConnection.send(
                        .data(DoubaoStreamingProtocol.makeAudioRequest(remainder, isFinal: false))
                    )
                }
                try await freshConnection.send(
                    .data(DoubaoStreamingProtocol.makeAudioRequest(Data(), isFinal: true))
                )
            }

            earlyRecoveryAudio.removeAll(keepingCapacity: false)
            earlyRecoveryInitialRequest = nil
            earlyRecoveryTarget = nil
            earlyRecoveryCommitRequested = false
            finishEarlyRecovery(succeeded: true)
            Self.logger.notice(
                "Doubao early recovery completed elapsed=\(Date().timeIntervalSince(recoveryStartedAt), format: .fixed(precision: 3), privacy: .public)s \(target.key.diagnosticLabel, privacy: .public)"
            )
            return true
        } catch {
            freshConnection?.close()
            if let currentConnection = connection, let freshConnection,
                currentConnection === freshConnection
            {
                connection = nil
            }
            earlyRecoveryAudio.removeAll(keepingCapacity: false)
            finishEarlyRecovery(succeeded: false)
            if !(error is CancellationError) {
                Self.logger.error(
                    "Doubao early recovery failed elapsed=\(Date().timeIntervalSince(recoveryStartedAt), format: .fixed(precision: 3), privacy: .public)s error=\(error.localizedDescription, privacy: .public) \(target.key.diagnosticLabel, privacy: .public)"
                )
            }
            return false
        }
    }

    private func bufferAudioForEarlyRecovery(_ data: Data) {
        guard !earlyRecoveryBufferOverflowed else { return }
        guard data.count <= Self.maxEarlyRecoveryAudioBytes - earlyRecoveryAudio.count else {
            earlyRecoveryBufferOverflowed = true
            earlyRecoveryAudio.removeAll(keepingCapacity: false)
            Self.logger.error(
                "Doubao early-recovery audio buffer limit reached maxBytes=\(Self.maxEarlyRecoveryAudioBytes, privacy: .public)"
            )
            return
        }
        earlyRecoveryAudio.append(data)
    }

    private func markServerResponseReceived() {
        guard earlyRecoveryIsEligible else { return }
        earlyRecoveryIsEligible = false
        earlyRecoveryAudio.removeAll(keepingCapacity: false)
        earlyRecoveryInitialRequest = nil
        earlyRecoveryTarget = nil
        earlyRecoveryCommitRequested = false
    }

    private func finishEarlyRecovery(succeeded: Bool) {
        isRecoveringEarly = false
        let waiters = earlyRecoveryWaiters
        earlyRecoveryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: succeeded)
        }
    }

    private func resetEarlyRecoveryState() {
        finishEarlyRecovery(succeeded: false)
        earlyRecoveryTarget = nil
        earlyRecoveryInitialRequest = nil
        earlyRecoveryAudio.removeAll(keepingCapacity: false)
        earlyRecoveryIsEligible = false
        earlyRecoveryWasAttempted = false
        earlyRecoveryBufferOverflowed = false
        earlyRecoveryCommitRequested = false
    }

    private func closeSocket() {
        audioPacketizer.reset()
        connection?.close()
        connection = nil
    }

    private func releaseAttemptOwnership() async {
        guard ownsAttempt else { return }
        ownsAttempt = false
        await attemptCoordinator.release(attemptID)
    }
}
