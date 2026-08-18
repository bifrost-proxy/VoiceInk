import Foundation
import os

protocol DoubaoReplayTranscribing: Sendable {
    func transcribe(
        wavData: Data,
        apiKey: String,
        resourceID: String,
        customVocabulary: [String],
        settings: DoubaoSpeechSettings,
        recognitionContext: RecognitionContextEnvelope?
    ) async throws -> String
}

struct DoubaoWAVPayload: Sendable {
    let pcmData: Data

    init(data: Data) throws {
        guard data.count >= 12,
            String(data: data[0..<4], encoding: .ascii) == "RIFF",
            String(data: data[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw AudioProcessor.AudioProcessingError.invalidAudioFile
        }

        var format: (encoding: UInt16, channels: UInt16, sampleRate: UInt32, bitDepth: UInt16)?
        var payload: Data?
        var offset = 12

        while offset + 8 <= data.count {
            let chunkName = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(Self.readUInt32LE(data, at: offset + 4))
            let chunkStart = offset + 8
            guard chunkSize <= data.count - chunkStart else {
                throw AudioProcessor.AudioProcessingError.invalidAudioFile
            }
            let chunkEnd = chunkStart + chunkSize

            if chunkName == "fmt ", chunkSize >= 16 {
                format = (
                    encoding: Self.readUInt16LE(data, at: chunkStart),
                    channels: Self.readUInt16LE(data, at: chunkStart + 2),
                    sampleRate: Self.readUInt32LE(data, at: chunkStart + 4),
                    bitDepth: Self.readUInt16LE(data, at: chunkStart + 14)
                )
            } else if chunkName == "data" {
                payload = data.subdata(in: chunkStart..<chunkEnd)
            }

            offset = chunkEnd + (chunkSize % 2)
        }

        guard let format, let payload, !payload.isEmpty else {
            throw AudioProcessor.AudioProcessingError.invalidAudioFile
        }
        guard format.encoding == 1,
            format.channels == 1,
            format.sampleRate == 16_000,
            format.bitDepth == 16,
            payload.count.isMultiple(of: MemoryLayout<Int16>.size)
        else {
            throw AudioProcessor.AudioProcessingError.unsupportedFormat
        }

        pcmData = payload
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

struct DoubaoWebSocketReplayTranscriber: DoubaoReplayTranscribing {
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "DoubaoWebSocketReplayTranscriber"
    )
    private let connectionPool: CloudSpeechConnectionPool
    private let connector: any CloudSpeechWebSocketConnecting
    private let paceAudioInRealtime: Bool

    init(
        connectionPool: CloudSpeechConnectionPool = .shared,
        connector: any CloudSpeechWebSocketConnecting = URLSessionCloudSpeechWebSocketConnector(),
        paceAudioInRealtime: Bool = true
    ) {
        self.connectionPool = connectionPool
        self.connector = connector
        self.paceAudioInRealtime = paceAudioInRealtime
    }

    func transcribe(
        wavData: Data,
        apiKey: String,
        resourceID: String,
        customVocabulary: [String],
        settings: DoubaoSpeechSettings,
        recognitionContext: RecognitionContextEnvelope?
    ) async throws -> String {
        let startedAt = Date()
        var stage = "parse"
        var session: DoubaoWebSocketSession?

        do {
            let payload = try DoubaoWAVPayload(data: wavData)
            let estimatedDuration = Double(payload.pcmData.count) / Double(16_000 * MemoryLayout<Int16>.size)
            logger.notice(
                "Doubao full-file fallback started stage=parse pcmBytes=\(payload.pcmData.count, privacy: .public) audioDuration=\(estimatedDuration, format: .fixed(precision: 3), privacy: .public)s paceRealtime=\(self.paceAudioInRealtime, privacy: .public)"
            )
            let replaySession = DoubaoWebSocketSession(
                eventsContinuation: nil,
                connectionPool: connectionPool,
                connector: connector
            )
            session = replaySession
            stage = "connect"
            try await replaySession.connect(
                apiKey: apiKey,
                resourceID: resourceID,
                customVocabulary: customVocabulary,
                settings: settings,
                recognitionContext: recognitionContext,
                endpoint: .optimizedStreaming,
                startReceiving: false,
                allowPreconnectedConnection: false
            )

            stage = "send"
            var offset = 0
            while offset < payload.pcmData.count {
                try Task.checkCancellation()
                let packetByteCount = offset == 0
                    ? DoubaoAudioPacketizer.firstPacketByteCount
                    : DoubaoAudioPacketizer.packetByteCount
                let end = min(offset + packetByteCount, payload.pcmData.count)
                let chunk = payload.pcmData.subdata(in: offset..<end)
                try await replaySession.sendAudioChunk(chunk)
                offset = end

                if paceAudioInRealtime {
                    let nanoseconds = UInt64(
                        Double(chunk.count) / Double(16_000 * MemoryLayout<Int16>.size) * 1_000_000_000
                    )
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
            }

            stage = "commit"
            try await replaySession.commit()
            stage = "finalResponse"
            let transcript = try await replaySession.receiveFinalTranscript()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await replaySession.disconnect()
            session = nil

            guard !transcript.isEmpty else {
                throw CloudTranscriptionError.noTranscriptionReturned
            }
            logger.notice(
                "Doubao full-file fallback completed outcome=success elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s chars=\(transcript.count, privacy: .public)"
            )
            return transcript
        } catch {
            await session?.disconnect()
            logger.error(
                "Doubao full-file fallback completed outcome=failure stage=\(stage, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
