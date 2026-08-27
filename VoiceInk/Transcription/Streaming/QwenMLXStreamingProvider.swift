import Foundation
import os

struct QwenMLXAudioBatcher {
    static let targetByteCount = 3_200  // 100 ms of PCM16 at 16 kHz mono.

    let targetByteCount: Int
    private var bufferedData = Data()

    init(targetByteCount: Int = Self.targetByteCount) {
        precondition(targetByteCount > 0)
        self.targetByteCount = targetByteCount
        bufferedData.reserveCapacity(targetByteCount)
    }

    var bufferedByteCount: Int { bufferedData.count }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        bufferedData.append(data)

        var batches: [Data] = []
        while bufferedData.count >= targetByteCount {
            batches.append(Data(bufferedData.prefix(targetByteCount)))
            bufferedData.removeFirst(targetByteCount)
        }
        return batches
    }

    mutating func flush() -> Data? {
        guard !bufferedData.isEmpty else { return nil }
        let remainder = bufferedData
        bufferedData.removeAll(keepingCapacity: true)
        return remainder
    }

    mutating func reset() {
        bufferedData.removeAll(keepingCapacity: true)
    }
}

/// Native incremental Qwen3-ASR streaming on the MLX Metal GPU backend.
///
/// Unlike `BufferedOnDeviceStreamingProvider`, this provider sends each new
/// PCM block into one persistent decoder state. The bridge returns both the
/// monotonic stable prefix and the current revisable suffix.
final class QwenMLXStreamingProvider: StreamingTranscriptionProvider {
    private let runtime: QwenMLXRuntime
    private let context: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "QwenMLXStreaming")
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var lastText = ""
    private var connected = false
    private var audioBatcher = QwenMLXAudioBatcher()

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(runtime: QwenMLXRuntime = .shared, context: String? = nil) {
        self.runtime = runtime
        self.context = context
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let model = model as? QwenMLXModel else {
            throw StreamingTranscriptionError.connectionFailed("Invalid Qwen MLX model")
        }
        guard await QwenMLXModelManager.shared.isReady(model) else {
            throw StreamingTranscriptionError.connectionFailed("模型或 MLX 运行时尚未安装")
        }

        let backend = try await runtime.load(model: model)
        _ = try await runtime.beginStreaming(
            language: language,
            context: context,
            // Two-second chunks gave the best stream/batch consistency in the
            // local benchmark while retaining native incremental decoding.
            chunkSizeSeconds: 2.0,
            maxContextSeconds: 30.0
        )
        connected = true
        lastText = ""
        audioBatcher.reset()
        eventsContinuation?.yield(.sessionStarted)
        logger.notice(
            "Qwen MLX native streaming started backend=\(backend, privacy: .public) model=\(model.displayName, privacy: .public)"
        )
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard connected else { throw StreamingTranscriptionError.notConnected }
        guard !data.isEmpty else { return }

        for batch in audioBatcher.append(data) {
            try await feedAudioBatch(batch)
        }
    }

    private func feedAudioBatch(_ data: Data) async throws {
        let snapshot = try await runtime.feedAudio(data)
        guard snapshot.text != lastText else { return }
        lastText = snapshot.text
        eventsContinuation?.yield(
            .snapshot(text: snapshot.text, stableText: snapshot.stableText)
        )
    }

    func commit() async throws {
        guard connected else { throw StreamingTranscriptionError.notConnected }
        if let remainder = audioBatcher.flush() {
            try await feedAudioBatch(remainder)
        }
        let snapshot = try await runtime.finishStreaming()
        connected = false
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        eventsContinuation?.yield(.committed(text: text))
        logger.notice(
            "Qwen MLX stream finalized chunks=\(snapshot.chunksProcessed, privacy: .public) rewrites=\(snapshot.rewriteEvents, privacy: .public) stableChars=\(snapshot.stableText.count, privacy: .public)"
        )
    }

    func disconnect() async {
        if connected {
            await runtime.cancelStreaming()
        }
        connected = false
        audioBatcher.reset()
        eventsContinuation?.finish()
        logger.notice("Qwen MLX streaming disconnected; unresponsive bridge cleanup bounded")
    }
}
