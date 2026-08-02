import Foundation
import os

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
        eventsContinuation?.yield(.sessionStarted)
        logger.notice(
            "Qwen MLX native streaming started backend=\(backend, privacy: .public) model=\(model.displayName, privacy: .public)"
        )
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard connected else { throw StreamingTranscriptionError.notConnected }
        guard !data.isEmpty else { return }

        let snapshot = try await runtime.feedAudio(data)
        guard snapshot.text != lastText else { return }
        lastText = snapshot.text
        eventsContinuation?.yield(
            .snapshot(text: snapshot.text, stableText: snapshot.stableText)
        )
    }

    func commit() async throws {
        guard connected else { throw StreamingTranscriptionError.notConnected }
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
        eventsContinuation?.finish()
        logger.notice("Qwen MLX streaming disconnected; resident model retained")
    }
}
