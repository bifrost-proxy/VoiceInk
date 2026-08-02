import Foundation
import os

/// Provides incremental live transcription for fast offline models. Only the
/// current bounded audio window is decoded; finalized windows are accumulated
/// and the stop path decodes only the remaining tail.
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
    private let minimumSamples = 12_000
    private let minimumNewSamples = 12_000
    private let minimumSegmentSamples = 24_000
    private let maximumSegmentSamples = 192_000
    private let forcedWindowOverlapSamples = 16_000
    private let silenceProbeSamples = 9_600
    private let silenceRMSLimit: Float = 0.0018
    private let bufferLock = NSLock()

    private var audioBuffer: [Float] = []
    private var lastTranscribedSampleCount = 0
    private var transcriptAssembler = IncrementalTranscriptAssembler()
    private var modelName: String?
    private var transcriptionTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    var stopDisposition: StreamingStopDisposition { .finalizeStreaming }

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
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        if let cachedFinalText = bufferLock.withLock({ () -> String? in
            guard !audioBuffer.isEmpty,
                lastTranscribedSampleCount == audioBuffer.count,
                !transcriptAssembler.partialText.isEmpty
            else {
                return nil
            }

            let finalText = transcriptAssembler.finalize("")
            audioBuffer.removeAll()
            lastTranscribedSampleCount = 0
            return finalText
        }) {
            logger.notice("Finalized the latest incremental preview without re-decoding audio")
            eventsContinuation?.yield(.committed(text: cachedFinalText))
            return
        }

        await runTranscriptionPass(force: true, commit: true)
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
                    try await Task.sleep(for: .milliseconds(700))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runTranscriptionPass(force: false, commit: false)
            }
        }
    }

    private func runTranscriptionPass(force: Bool, commit: Bool) async {
        guard let modelName else { return }

        guard let snapshot = bufferLock.withLock({ () -> (samples: [Float], sampleCount: Int)? in
            let sampleCount = audioBuffer.count
            if commit, sampleCount == 0 {
                return ([], 0)
            }
            guard sampleCount > 0 else { return nil }
            guard force
                || (sampleCount >= minimumSamples
                    && sampleCount - lastTranscribedSampleCount >= minimumNewSamples)
            else {
                return nil
            }
            return (audioBuffer, sampleCount)
        }) else {
            return
        }
        if commit, snapshot.samples.isEmpty {
            let finalText = bufferLock.withLock { transcriptAssembler.finalizedText }
            eventsContinuation?.yield(.committed(text: finalText))
            return
        }

        let reachedWindowLimit = snapshot.sampleCount >= maximumSegmentSamples
        let endedAtPause = snapshot.sampleCount >= minimumSegmentSamples
            && Self.isTrailingSilence(
                in: snapshot.samples,
                probeSamples: silenceProbeSamples,
                rmsLimit: silenceRMSLimit
            )
        let shouldFinalizeWindow = commit || reachedWindowLimit || endedAtPause

        do {
            let text: String
            switch backend {
            case .funASR(let service):
                text = try await service.transcribeBufferedStreamingPreview(
                    samples: snapshot.samples,
                    modelName: modelName
                )
            case .qwen3ASR(let service):
                text = try await service.transcribeBufferedStreamingPreview(
                    samples: snapshot.samples,
                    modelName: modelName
                )
            }

            let cumulativeText = bufferLock.withLock { () -> String in
                if shouldFinalizeWindow {
                    let finalized = transcriptAssembler.finalize(text)
                    let overlap = reachedWindowLimit && !commit
                        ? min(forcedWindowOverlapSamples, snapshot.sampleCount)
                        : 0
                    let samplesToRemove = snapshot.sampleCount - overlap
                    if samplesToRemove > 0, audioBuffer.count >= samplesToRemove {
                        audioBuffer.removeFirst(samplesToRemove)
                    }
                    lastTranscribedSampleCount = overlap
                    return finalized
                }

                lastTranscribedSampleCount = snapshot.sampleCount
                return transcriptAssembler.updatePartial(text)
            }
            if commit {
                eventsContinuation?.yield(.committed(text: cumulativeText))
            } else if !cumulativeText.isEmpty {
                eventsContinuation?.yield(.partial(text: cumulativeText))
            }
            if shouldFinalizeWindow {
                let reason = commit ? "stop" : (endedAtPause ? "pause" : "window-limit")
                logger.notice(
                    "Incremental window finalized reason=\(reason, privacy: .public) samples=\(snapshot.sampleCount, privacy: .public) cumulativeChars=\(cumulativeText.count, privacy: .public)"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Buffered preview pass failed: \(error, privacy: .public)")
            if commit {
                let fallbackText = bufferLock.withLock {
                    transcriptAssembler.finalize("")
                }
                eventsContinuation?.yield(.committed(text: fallbackText))
            }
        }
    }

    private func resetBuffer() {
        bufferLock.withLock {
            audioBuffer = []
            lastTranscribedSampleCount = 0
            transcriptAssembler.reset()
        }
    }

    static func isTrailingSilence(in samples: [Float], probeSamples: Int, rmsLimit: Float) -> Bool {
        guard probeSamples > 0, samples.count >= probeSamples else { return false }
        let tail = samples.suffix(probeSamples)
        let energy = tail.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(energy / Float(probeSamples)) <= rmsLimit
    }
}
