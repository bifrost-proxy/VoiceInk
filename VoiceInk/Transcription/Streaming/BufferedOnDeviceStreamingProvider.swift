import Foundation
import os

/// Provides live previews for fast offline models by periodically re-decoding the
/// audio collected so far. The recording's complete file is still used for the
/// final transcript, so a preview failure never compromises the final result.
final class BufferedOnDeviceStreamingProvider: StreamingTranscriptionProvider {
    enum Backend {
        case funASR(FluidAudioTranscriptionService)
        case qwen3ASR(SherpaOnnxTranscriptionService)
    }

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "BufferedOnDeviceStreaming"
    )
    private let backend: Backend
    private let minimumSamples = 24_000
    private let minimumNewSamples = 16_000
    private let trailingSilenceSamples = 3_200
    private let bufferLock = NSLock()

    private var audioBuffer: [Float] = []
    private var lastTranscribedSampleCount = 0
    private var modelName: String?
    private var transcriptionTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    var stopDisposition: StreamingStopDisposition { .useBatchFallback }

    init(backend: Backend) {
        self.backend = backend
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        transcriptionTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        switch backend {
        case .funASR(let service):
            try await service.prepareBufferedStreamingPreview(named: model.name)
        case .qwen3ASR(let service):
            try await service.prepareBufferedStreamingPreview(named: model.name)
        }

        modelName = model.name
        resetBuffer()

        startTranscriptionLoop()
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Buffered preview started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        let samples = PCMAudioConverter.float32Samples(fromPCM16Data: data)
        guard !samples.isEmpty else { return }

        bufferLock.withLock {
            audioBuffer.append(contentsOf: samples)
        }
    }

    func commit() async throws {
        // stopDisposition always requests a final pass over the complete audio file.
    }

    func disconnect() async {
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        resetBuffer()
        modelName = nil

        eventsContinuation?.finish()
        logger.notice("Buffered preview disconnected")
    }

    private func startTranscriptionLoop() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runTranscriptionPass()
            }
        }
    }

    private func runTranscriptionPass() async {
        guard let modelName else { return }

        guard let snapshot = bufferLock.withLock({ () -> (samples: [Float], sampleCount: Int)? in
            let sampleCount = audioBuffer.count
            guard sampleCount >= minimumSamples,
                sampleCount - lastTranscribedSampleCount >= minimumNewSamples
            else {
                return nil
            }
            return (audioBuffer, sampleCount)
        }) else {
            return
        }
        var samples = snapshot.samples

        samples.append(contentsOf: repeatElement(0, count: trailingSilenceSamples))

        do {
            let text: String
            switch backend {
            case .funASR(let service):
                text = try await service.transcribeBufferedStreamingPreview(
                    samples: samples,
                    modelName: modelName
                )
            case .qwen3ASR(let service):
                text = try await service.transcribeBufferedStreamingPreview(
                    samples: samples,
                    modelName: modelName
                )
            }

            guard !Task.isCancelled else { return }
            bufferLock.withLock {
                lastTranscribedSampleCount = snapshot.sampleCount
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                eventsContinuation?.yield(.partial(text: trimmed))
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Buffered preview pass failed: \(error, privacy: .public)")
        }
    }

    private func resetBuffer() {
        bufferLock.withLock {
            audioBuffer = []
            lastTranscribedSampleCount = 0
        }
    }
}
