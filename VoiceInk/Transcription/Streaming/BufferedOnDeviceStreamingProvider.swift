import Foundation
import os

/// Provides incremental live transcription for fast offline models. Only the
/// current bounded audio window is decoded; finalized windows are accumulated
/// and the stop path decodes only the remaining tail.
final class BufferedOnDeviceStreamingProvider: StreamingTranscriptionProvider {
    struct Configuration {
        let previewInterval: Duration
        let minimumSamples: Int
        let minimumNewSamples: Int
        let minimumSegmentSamples: Int
        let maximumSegmentSamples: Int
        let forcedWindowOverlapSamples: Int
        let pauseWindowOverlapSamples: Int
        let silenceProbeSamples: Int
        let silenceRMSLimit: Float
        let finalizesAtPause: Bool

        static let `default` = Configuration(
            previewInterval: .milliseconds(700),
            minimumSamples: 12_000,
            minimumNewSamples: 12_000,
            minimumSegmentSamples: 24_000,
            // SenseVoice may not have emitted the end of an uninterrupted
            // sentence at twelve seconds, so keep a larger bounded window.
            maximumSegmentSamples: 480_000,
            forcedWindowOverlapSamples: 16_000,
            pauseWindowOverlapSamples: 3_200,
            silenceProbeSamples: 9_600,
            silenceRMSLimit: 0.0018,
            // Keep pauses provisional. Finalizing on a brief quiet interval
            // changes later decoding context and can produce a very different
            // final sentence even for short recordings.
            finalizesAtPause: false
        )

        /// The CTC model is non-autoregressive and fast enough to refresh a
        /// zero-padded short hypothesis without waiting for its 15-second
        /// tensor to fill. This normally yields the first preview in ~0.9 s.
        static let fastPreview = Configuration(
            previewInterval: .milliseconds(450),
            minimumSamples: 8_000,
            minimumNewSamples: 8_000,
            minimumSegmentSamples: 24_000,
            maximumSegmentSamples: 240_000,
            forcedWindowOverlapSamples: 16_000,
            pauseWindowOverlapSamples: 0,
            silenceProbeSamples: 9_600,
            silenceRMSLimit: 0.0018,
            finalizesAtPause: false
        )

        /// Qwen runs on the CPU and benefits from a smaller first window. The
        /// loop sleeps after each inference, so this improves first-text
        /// latency without allowing overlapping decoder work.
        static let responsivePreview = Configuration(
            previewInterval: .milliseconds(450),
            minimumSamples: 6_400,
            minimumNewSamples: 6_400,
            minimumSegmentSamples: 24_000,
            maximumSegmentSamples: 480_000,
            forcedWindowOverlapSamples: 16_000,
            pauseWindowOverlapSamples: 0,
            silenceProbeSamples: 9_600,
            silenceRMSLimit: 0.0018,
            finalizesAtPause: false
        )
    }

    enum Backend {
        case funASR(FluidAudioTranscriptionService)
        case qwen3ASR(SherpaOnnxTranscriptionService)
    }

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "BufferedOnDeviceStreaming"
    )
    private let backend: Backend
    private let configuration: Configuration
    private let bufferLock = NSLock()

    private var audioBuffer: [Float] = []
    private var lastTranscribedSampleCount = 0
    private var latestDecodedText: String?
    private var transcriptAssembler = IncrementalTranscriptAssembler()
    private var modelName: String?
    private var transcriptionTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    var stopDisposition: StreamingStopDisposition { .finalizeStreaming }

    init(backend: Backend, configuration: Configuration = .default) {
        self.backend = backend
        self.configuration = configuration
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

        if let cachedFinalText = takeCoveredFinalText() {
            logger.notice("Finalized the latest fully covered window without re-decoding audio")
            eventsContinuation?.yield(.committed(text: cachedFinalText))
            return
        }

        // Refresh only the bounded, unconfirmed window at stop. Previously
        // finalized windows are not decoded again.
        while true {
            let beforeCount = bufferLock.withLock { audioBuffer.count }
            await runTranscriptionPass(force: true, commit: false)
            let afterCount = bufferLock.withLock { audioBuffer.count }
            if afterCount >= beforeCount { break }
        }

        if let finalText = takeCoveredFinalText() {
            eventsContinuation?.yield(.committed(text: finalText))
        } else {
            await runTranscriptionPass(force: true, commit: true)
        }
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
        let previewInterval = configuration.previewInterval
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: previewInterval)
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
                || (sampleCount >= configuration.minimumSamples
                    && sampleCount - lastTranscribedSampleCount >= configuration.minimumNewSamples)
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

        let pauseBoundary = configuration.finalizesAtPause
            ? Self.pauseBoundary(
                in: snapshot.samples,
                minimumSegmentSamples: configuration.minimumSegmentSamples,
                probeSamples: configuration.silenceProbeSamples,
                rmsLimit: configuration.silenceRMSLimit
            )
            : nil
        let endedAtPause = pauseBoundary != nil
        let reachedWindowLimit = pauseBoundary == nil
            && snapshot.sampleCount >= configuration.maximumSegmentSamples
        let decodedSampleCount = pauseBoundary
            ?? (reachedWindowLimit ? configuration.maximumSegmentSamples : snapshot.sampleCount)
        let samplesToDecode = decodedSampleCount == snapshot.sampleCount
            ? snapshot.samples
            : Array(snapshot.samples.prefix(decodedSampleCount))
        let shouldFinalizeWindow = commit || reachedWindowLimit || endedAtPause

        do {
            let text: String
            switch backend {
            case .funASR(let service):
                text = try await service.transcribeBufferedStreamingPreview(
                    samples: samplesToDecode,
                    modelName: modelName
                )
            case .qwen3ASR(let service):
                text = try await service.transcribeBufferedStreamingPreview(
                    samples: samplesToDecode,
                    modelName: modelName
                )
            }

            let cumulativeText = bufferLock.withLock { () -> String in
                latestDecodedText = text
                if shouldFinalizeWindow {
                    let finalized = commit
                        ? transcriptAssembler.finalizeAuthoritative(text)
                        : transcriptAssembler.finalize(text)
                    let overlap: Int
                    if reachedWindowLimit && !commit {
                        overlap = min(configuration.forcedWindowOverlapSamples, decodedSampleCount)
                    } else if endedAtPause && !commit {
                        // Retain 200 ms of the detected quiet interval so the
                        // next phrase never starts exactly on a clipped onset.
                        overlap = min(configuration.pauseWindowOverlapSamples, decodedSampleCount)
                    } else {
                        overlap = 0
                    }
                    let samplesToRemove = decodedSampleCount - overlap
                    if samplesToRemove > 0, audioBuffer.count >= samplesToRemove {
                        audioBuffer.removeFirst(samplesToRemove)
                    }
                    lastTranscribedSampleCount = overlap
                    latestDecodedText = nil
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
                    "Incremental window finalized reason=\(reason, privacy: .public) samples=\(decodedSampleCount, privacy: .public) cumulativeChars=\(cumulativeText.count, privacy: .public)"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Buffered preview pass failed: \(error, privacy: .public)")
            if commit {
                let fallbackText = bufferLock.withLock {
                    transcriptAssembler.finalizeAuthoritative("")
                }
                eventsContinuation?.yield(.committed(text: fallbackText))
            }
        }
    }

    private func resetBuffer() {
        bufferLock.withLock {
            audioBuffer = []
            lastTranscribedSampleCount = 0
            latestDecodedText = nil
            transcriptAssembler.reset()
        }
    }

    private func takeCoveredFinalText() -> String? {
        bufferLock.withLock {
            guard !audioBuffer.isEmpty,
                lastTranscribedSampleCount == audioBuffer.count,
                let latestDecodedText
            else {
                return nil
            }

            let finalText = transcriptAssembler.finalizeAuthoritative(latestDecodedText)
            audioBuffer.removeAll()
            lastTranscribedSampleCount = 0
            self.latestDecodedText = nil
            return finalText
        }
    }

    /// Returns the end of the latest complete quiet interval. Looking across
    /// the whole new snapshot avoids missing a pause merely because speech
    /// resumed before the next 700 ms preview tick.
    static func pauseBoundary(
        in samples: [Float],
        minimumSegmentSamples: Int,
        probeSamples: Int,
        rmsLimit: Float
    ) -> Int? {
        guard minimumSegmentSamples > 0,
            probeSamples > 0,
            samples.count >= max(minimumSegmentSamples, probeSamples)
        else {
            return nil
        }

        let energyLimit = rmsLimit * rmsLimit * Float(probeSamples)
        let speechAmplitudeLimit = max(rmsLimit * 3, 0.005)
        let minimumAudibleSamples = 800
        var audiblePrefix = [Int](repeating: 0, count: samples.count + 1)
        for index in samples.indices {
            audiblePrefix[index + 1] = audiblePrefix[index]
                + (abs(samples[index]) >= speechAmplitudeLimit ? 1 : 0)
        }
        var energy = samples.prefix(probeSamples).reduce(Float.zero) { $0 + $1 * $1 }
        var latestBoundary: Int?

        for end in probeSamples...samples.count {
            let windowStart = end - probeSamples
            let audibleBeforePause = audiblePrefix[windowStart]
            let audibleAfterPause = audiblePrefix[samples.count] - audiblePrefix[end]
            if end >= minimumSegmentSamples,
                energy <= energyLimit,
                audibleBeforePause >= minimumAudibleSamples,
                audibleAfterPause >= minimumAudibleSamples
            {
                latestBoundary = end
            }
            guard end < samples.count else { break }
            let outgoing = samples[end - probeSamples]
            let incoming = samples[end]
            energy += incoming * incoming - outgoing * outgoing
        }

        return latestBoundary
    }

    static func isTrailingSilence(in samples: [Float], probeSamples: Int, rmsLimit: Float) -> Bool {
        guard probeSamples > 0, samples.count >= probeSamples else { return false }
        let tail = samples.suffix(probeSamples)
        let energy = tail.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(energy / Float(probeSamples)) <= rmsLimit
    }
}
