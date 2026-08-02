import Foundation
import SwiftData
import Testing
@testable import VoiceInk

/// Opt-in, real-model benchmark for comparing whole-file inference with the
/// exact realtime session path used by the recorder. It is intentionally not
/// part of normal CI because it reads downloaded models and private recordings.
struct ASRStreamingBenchmarkTests {
    @MainActor
    @Test func compareRecentRecordingsAcrossDownloadedRealtimeModels() async throws {
        #if !VOICEINK_ASR_BENCHMARK
            return
        #endif

        let environment = ProcessInfo.processInfo.environment

        AppDefaults.registerDefaults()
        ModeManager.shared.reloadFromSynchronizedDefaults()

        let recordingsDirectory = URL(
            fileURLWithPath: environment["VOICEINK_BENCHMARK_RECORDINGS_DIR"]
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings",
                        isDirectory: true
                    ).path,
            isDirectory: true
        )
        let outputDirectory: URL
        if let configuredOutput = environment["VOICEINK_BENCHMARK_OUTPUT_DIR"], !configuredOutput.isEmpty {
            outputDirectory = URL(fileURLWithPath: configuredOutput, isDirectory: true)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/com.prakashjoshipax.VoiceInk/Benchmarks",
                    isDirectory: true
                )
                .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        }
        #if VOICEINK_ASR_BENCHMARK_SMOKE
            let requestedCount = 1
            let replayInRealtime = true
            let shouldEnhance = false
        #else
            let requestedCount = max(Int(environment["VOICEINK_BENCHMARK_AUDIO_COUNT"] ?? "10") ?? 10, 1)
            let replayInRealtime = environment["VOICEINK_BENCHMARK_FAST_REPLAY"] != "1"
            let shouldEnhance = environment["VOICEINK_BENCHMARK_SKIP_ENHANCEMENT"] != "1"
        #endif

        let audioURLs = try Self.mostRecentWAVFiles(in: recordingsDirectory, limit: requestedCount)
        #expect(audioURLs.count == requestedCount, "Expected \(requestedCount) recent WAV recordings")

        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let modelContext = container.mainContext
        let fluidAudioService = FluidAudioTranscriptionService()
        let sherpaOnnxService = SherpaOnnxTranscriptionService()
        let fluidAudioModelManager = FluidAudioModelManager()
        #if VOICEINK_ASR_BENCHMARK_SMOKE
            let requestedModelNames: [String]? = ["qwen3-asr-0.6b-int8"]
        #else
            let requestedModelNames = environment["VOICEINK_BENCHMARK_MODELS"]?
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        #endif

        let downloadedModels: [any TranscriptionModel] = TranscriptionModelRegistry.models
            .filter { model in
                (requestedModelNames == nil || requestedModelNames?.contains(model.name) == true)
                    && Self.isDownloaded(
                        model,
                        fluidAudioModelManager: fluidAudioModelManager,
                        sherpaOnnxModelManager: .shared
                    )
                    && TranscriptionRealtimeSupport.mode(for: model) != .batchOnly
            }

        #expect(!downloadedModels.isEmpty, "No downloaded realtime-capable local models found")

        let activeMode = ModeManager.shared.currentEffectiveConfiguration
        let enhancementHarness = shouldEnhance
            ? Self.makeEnhancementHarness(modelContext: modelContext, mode: activeMode)
            : nil
        var enhancementCache: [String: EnhancementResult] = [:]
        var cases: [CaseResult] = []

        for model in downloadedModels {
            for audioURL in audioURLs {
                let wav = try WAVPayload(url: audioURL)
                print(
                    "VOICEINK_ASR_BENCHMARK_CASE_START "
                        + "model=\(model.name) audio=\(audioURL.lastPathComponent) "
                        + "duration=\(Self.format(wav.durationSeconds))s"
                )
                let requestContext = TranscriptionRequestContext(language: "auto", prompt: nil)
                let transcriptionService: any TranscriptionService = switch model.provider {
                case .fluidAudio: fluidAudioService
                case .sherpaOnnx: sherpaOnnxService
                default: fatalError("Unsupported local benchmark provider: \(model.provider)")
                }

                let baselineStart = Date()
                let baseline = await Self.capture {
                    try await transcriptionService.transcribe(
                        audioURL: audioURL,
                        model: model,
                        context: requestContext
                    )
                }
                let baselineSeconds = Date().timeIntervalSince(baselineStart)
                let baselineRepeatStart = Date()
                let baselineRepeat = await Self.capture {
                    try await transcriptionService.transcribe(
                        audioURL: audioURL,
                        model: model,
                        context: requestContext
                    )
                }
                let baselineRepeatSeconds = Date().timeIntervalSince(baselineRepeatStart)
                let baselineRepeatSimilarity = Self.similarity(baseline.text, baselineRepeat.text)

                let mode = ModeConfig(
                    name: "ASR Benchmark",
                    isAIEnhancementEnabled: false,
                    selectedTranscriptionModelName: model.name,
                    isRealtimeTranscriptionEnabled: true,
                    selectedLanguage: "auto"
                )
                let configuration = TranscriptionRuntimeConfiguration(
                    mode: mode,
                    model: model,
                    language: "auto",
                    isRealtimeEnabled: true
                )
                var partials: [PartialResult] = []
                let streamStart = Date()
                var firstPartialSeconds: TimeInterval?
                let streamingService = StreamingTranscriptionService(
                    modelContext: modelContext,
                    fluidAudioService: model.provider == .fluidAudio ? fluidAudioService : nil,
                    sherpaOnnxService: model.provider == .sherpaOnnx ? sherpaOnnxService : nil,
                    onPartialTranscript: { partial in
                        let elapsed = Date().timeIntervalSince(streamStart)
                        if firstPartialSeconds == nil, !partial.isEmpty {
                            firstPartialSeconds = elapsed
                        }
                        guard partials.last?.text != partial else { return }
                        partials.append(PartialResult(seconds: elapsed, text: partial))
                        if partials.count > 30 {
                            partials.removeFirst(partials.count - 30)
                        }
                    }
                )
                let session = StreamingTranscriptionSession(
                    streamingService: streamingService,
                    fallbackService: transcriptionService
                )

                var streaming: CapturedText
                var finalizeSeconds: TimeInterval = 0
                do {
                    let callback = try await session.prepare(configuration: configuration)
                    if let callback {
                        try await Self.replay(
                            wav.pcmData,
                            callback: callback,
                            realtime: replayInRealtime
                        )
                    }
                    let finalizeStart = Date()
                    streaming = await Self.capture {
                        try await session.transcribe(audioURL: audioURL)
                    }
                    finalizeSeconds = Date().timeIntervalSince(finalizeStart)
                } catch {
                    streaming = CapturedText(text: nil, error: String(describing: error))
                }
                let streamingSeconds = Date().timeIntervalSince(streamStart)

                let rawSimilarity = Self.similarity(baseline.text, streaming.text)
                let baselineEnhancement = await Self.enhance(
                    baseline.text,
                    harness: enhancementHarness,
                    cache: &enhancementCache
                )
                let streamingEnhancement = await Self.enhance(
                    streaming.text,
                    harness: enhancementHarness,
                    cache: &enhancementCache
                )
                let enhancedSimilarity = Self.similarity(
                    baselineEnhancement?.text,
                    streamingEnhancement?.text
                )

                let result = CaseResult(
                    modelName: model.name,
                    modelDisplayName: model.displayName,
                    realtimeMode: Self.realtimeModeName(for: model),
                    audioFile: audioURL.lastPathComponent,
                    audioDurationSeconds: wav.durationSeconds,
                    batchText: baseline.text,
                    batchError: baseline.error,
                    batchSeconds: baselineSeconds,
                    batchRepeatText: baselineRepeat.text,
                    batchRepeatError: baselineRepeat.error,
                    batchRepeatSeconds: baselineRepeatSeconds,
                    batchRepeatSimilarity: baselineRepeatSimilarity,
                    streamingText: streaming.text,
                    streamingError: streaming.error,
                    streamingSeconds: streamingSeconds,
                    finalizeSeconds: finalizeSeconds,
                    resolution: session.lastResolution?.rawValue,
                    firstPartialSeconds: firstPartialSeconds,
                    partials: partials,
                    rawSimilarity: rawSimilarity,
                    batchEnhancedText: baselineEnhancement?.text,
                    batchEnhancementError: baselineEnhancement?.error,
                    batchEnhancementSeconds: baselineEnhancement?.seconds,
                    streamingEnhancedText: streamingEnhancement?.text,
                    streamingEnhancementError: streamingEnhancement?.error,
                    streamingEnhancementSeconds: streamingEnhancement?.seconds,
                    enhancedSimilarity: enhancedSimilarity
                )
                cases.append(result)
                print(
                    "VOICEINK_ASR_BENCHMARK_CASE_END "
                        + "model=\(model.name) audio=\(audioURL.lastPathComponent) "
                        + "rawParity=\(Self.format(rawSimilarity)) "
                        + "enhancedParity=\(Self.format(enhancedSimilarity)) "
                        + "resolution=\(result.resolution ?? "none")"
                )
            }
            if model.provider == .fluidAudio {
                await fluidAudioService.cleanup()
            }
        }

        let report = BenchmarkReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            recordingsDirectory: recordingsDirectory.path,
            audioCount: audioURLs.count,
            replayedInRealtime: replayInRealtime,
            enhancementEnabled: enhancementHarness != nil,
            enhancementProvider: enhancementHarness?.configuration.provider?.rawValue,
            enhancementModel: enhancementHarness?.configuration.modelName,
            enhancementPrompt: enhancementHarness?.configuration.prompt?.title,
            historicalContextIncluded: false,
            cases: cases
        )

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let jsonURL = outputDirectory.appendingPathComponent("asr-streaming-benchmark.json")
        let markdownURL = outputDirectory.appendingPathComponent("asr-streaming-benchmark.md")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        try Self.markdown(for: report).write(to: markdownURL, atomically: true, encoding: .utf8)

        print("VOICEINK_ASR_BENCHMARK_JSON=\(jsonURL.path)")
        print("VOICEINK_ASR_BENCHMARK_MARKDOWN=\(markdownURL.path)")
    }

    @MainActor
    private static func isDownloaded(
        _ model: any TranscriptionModel,
        fluidAudioModelManager: FluidAudioModelManager,
        sherpaOnnxModelManager: SherpaOnnxModelManager
    ) -> Bool {
        if let model = model as? FluidAudioModel {
            return fluidAudioModelManager.isFluidAudioModelDownloaded(model)
        }
        if let model = model as? SherpaOnnxModel {
            return sherpaOnnxModelManager.isDownloaded(model)
        }
        return false
    }

    @MainActor
    private static func makeEnhancementHarness(
        modelContext: ModelContext,
        mode: ModeConfig?
    ) -> EnhancementHarness? {
        let aiService = AIService()
        let service = AIEnhancementService(aiService: aiService, modelContext: modelContext)
        let configuration = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: mode,
            enhancementService: service,
            aiService: aiService
        )
        guard configuration.isEnabled, service.isConfigured(for: configuration) else {
            return nil
        }
        return EnhancementHarness(service: service, configuration: configuration)
    }

    private static func enhance(
        _ text: String?,
        harness: EnhancementHarness?,
        cache: inout [String: EnhancementResult]
    ) async -> EnhancementResult? {
        guard let harness, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let cached = cache[text] { return cached }
        let start = Date()
        let result: EnhancementResult
        do {
            let enhanced = try await harness.service.enhance(
                text,
                configuration: harness.configuration,
                contextSnapshot: nil
            )
            result = EnhancementResult(
                text: enhanced.0,
                error: nil,
                seconds: Date().timeIntervalSince(start)
            )
        } catch {
            result = EnhancementResult(
                text: nil,
                error: String(describing: error),
                seconds: Date().timeIntervalSince(start)
            )
        }
        cache[text] = result
        return result
    }

    private static func capture(_ operation: () async throws -> String) async -> CapturedText {
        do {
            return CapturedText(text: try await operation(), error: nil)
        } catch {
            return CapturedText(text: nil, error: String(describing: error))
        }
    }

    private static func replay(
        _ pcmData: Data,
        callback: @escaping (Data) -> Void,
        realtime: Bool
    ) async throws {
        let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size
        let chunkBytes = bytesPerSecond / 10
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkBytes, pcmData.count)
            callback(pcmData.subdata(in: offset..<end))
            if realtime {
                let seconds = Double(end - offset) / Double(bytesPerSecond)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            offset = end
        }
    }

    private static func mostRecentWAVFiles(in directory: URL, limit: Int) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "wav" }
        .filter { (try? $0.resourceValues(forKeys: keys).isRegularFile) == true }
        .sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func realtimeModeName(for model: any TranscriptionModel) -> String {
        switch TranscriptionRealtimeSupport.mode(for: model) {
        case .nativeStreaming: return "nativeStreaming"
        case .slidingWindow: return "slidingWindow"
        case .batchOnly: return "batchOnly"
        }
    }

    private static func similarity(_ lhs: String?, _ rhs: String?) -> Double? {
        guard let lhs, let rhs else { return nil }
        let left = Array(lhs.lowercased().filter { $0.isLetter || $0.isNumber })
        let right = Array(rhs.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !left.isEmpty || !right.isEmpty else { return nil }
        let distance = levenshtein(left, right)
        return max(0, 1 - Double(distance) / Double(max(left.count, right.count)))
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, leftCharacter) in lhs.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func markdown(for report: BenchmarkReport) -> String {
        let grouped = Dictionary(grouping: report.cases, by: \CaseResult.modelName)
        var lines: [String] = [
            "# VoiceInk ASR realtime parity benchmark",
            "",
            "Generated: \(report.generatedAt)",
            "",
            "This report uses whole-file inference as a repeatable pseudo-reference, then replays the same PCM through the recorder's realtime session path. It detects integration gaps; it is not a human-labelled WER/CER accuracy test.",
            "",
            "- Recordings: \(report.audioCount) most recent WAV files from the live VoiceInk data directory",
            "- Replay timing: \(report.replayedInRealtime ? "real time, 100 ms PCM chunks" : "accelerated, 100 ms PCM chunks")",
            "- Enhancement: \(report.enhancementEnabled ? "\(report.enhancementProvider ?? "unknown") / \(report.enhancementModel ?? "unknown") / \(report.enhancementPrompt ?? "unknown")" : "not configured or explicitly skipped")",
            "- Historical screen, clipboard, and selected-text context: not available and therefore excluded",
            "",
            "## Summary",
            "",
            "| Model | Mode | Cases | Batch repeat | Repeat exact | Raw parity | Raw exact | Unscored | Enhanced parity | Enhanced exact | Fallbacks | Missing preview | ASR errors | Enhancement errors |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]

        for modelName in grouped.keys.sorted() {
            let items = grouped[modelName] ?? []
            let scores = items.compactMap(\CaseResult.rawSimilarity)
            let average = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            let exact = scores.filter { $0 == 1 }.count
            let unscored = items.count - scores.count
            let repeatScores = items.compactMap(\CaseResult.batchRepeatSimilarity)
            let repeatAverage = repeatScores.isEmpty
                ? nil
                : repeatScores.reduce(0, +) / Double(repeatScores.count)
            let repeatExact = repeatScores.filter { $0 == 1 }.count
            let enhancedScores = items.compactMap(\CaseResult.enhancedSimilarity)
            let enhancedAverage = enhancedScores.isEmpty
                ? nil
                : enhancedScores.reduce(0, +) / Double(enhancedScores.count)
            let enhancedExact = enhancedScores.filter { $0 == 1 }.count
            let fallbacks = items.filter {
                $0.resolution != StreamingTranscriptionSession.Resolution.streamingFinalized.rawValue
            }.count
            let missingPreview = items.filter { $0.audioDurationSeconds >= 1 && $0.firstPartialSeconds == nil }.count
            let errors = items.filter {
                $0.batchError != nil || $0.batchRepeatError != nil || $0.streamingError != nil
            }.count
            let enhancementErrors = items.filter {
                $0.batchEnhancementError != nil || $0.streamingEnhancementError != nil
            }.count
            let item = items[0]
            lines.append(
                "| \(item.modelDisplayName) | \(item.realtimeMode) | \(items.count) | \(format(repeatAverage)) | \(repeatExact) | \(format(average)) | \(exact) | \(unscored) | \(format(enhancedAverage)) | \(enhancedExact) | \(fallbacks) | \(missingPreview) | \(errors) | \(enhancementErrors) |"
            )
        }

        lines += ["", "## Bad cases and warnings", ""]
        let findings = report.cases.flatMap(findings(for:))
        if findings.isEmpty {
            lines.append("No integration gap crossed the configured thresholds.")
        } else {
            lines.append(contentsOf: findings.map { "- \($0)" })
        }

        lines += ["", "## Case details", ""]
        for item in report.cases {
            lines += [
                "### \(item.modelDisplayName) · \(item.audioFile)",
                "",
                "- Mode: `\(item.realtimeMode)`",
                "- Audio: \(format(item.audioDurationSeconds)) s",
                "- Batch: \(format(item.batchSeconds)) s; repeat \(format(item.batchRepeatSeconds)) s",
                "- Batch repeatability: \(format(item.batchRepeatSimilarity))",
                "- Realtime replay + finalize: \(format(item.streamingSeconds)) s; finalize \(format(item.finalizeSeconds)) s",
                "- Resolution: `\(item.resolution ?? "none")`",
                "- First partial: \(format(item.firstPartialSeconds)) s; changed partials retained: \(item.partials.count)",
                "- Raw parity: \(format(item.rawSimilarity))",
                "- Enhanced parity: \(format(item.enhancedSimilarity))",
                "",
                "Batch reference:",
                "",
                "```text",
                item.batchText ?? "ERROR: \(item.batchError ?? "empty")",
                "```",
                "",
                "Repeated batch reference:",
                "",
                "```text",
                item.batchRepeatText ?? "ERROR: \(item.batchRepeatError ?? "empty")",
                "```",
                "",
                "Realtime final:",
                "",
                "```text",
                item.streamingText ?? "ERROR: \(item.streamingError ?? "empty")",
                "```",
                "",
                "Batch reference after enhancement:",
                "",
                "```text",
                item.batchEnhancedText ?? "ERROR/SKIPPED: \(item.batchEnhancementError ?? "no result")",
                "```",
                "",
                "Realtime final after enhancement:",
                "",
                "```text",
                item.streamingEnhancedText ?? "ERROR/SKIPPED: \(item.streamingEnhancementError ?? "no result")",
                "```",
                "",
            ]
        }
        return lines.joined(separator: "\n")
    }

    private static func findings(for item: CaseResult) -> [String] {
        let prefix = "\(item.modelDisplayName) / \(item.audioFile):"
        var findings: [String] = []
        if let error = item.batchError { findings.append("\(prefix) batch error: \(error)") }
        if let error = item.batchRepeatError { findings.append("\(prefix) repeated batch error: \(error)") }
        if let error = item.streamingError { findings.append("\(prefix) realtime error: \(error)") }
        if item.batchError == nil,
            item.batchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            findings.append("\(prefix) whole-file pseudo-reference is empty; parity is unscored")
        }
        if let score = item.rawSimilarity, score < 0.98 {
            findings.append("\(prefix) raw batch/realtime parity is \(format(score))")
        }
        if let score = item.batchRepeatSimilarity, score < 0.98 {
            findings.append("\(prefix) identical whole-file inference repeatability is \(format(score))")
        }
        if let score = item.enhancedSimilarity, score < 0.98 {
            findings.append("\(prefix) enhanced batch/realtime parity is \(format(score))")
        }
        if item.audioDurationSeconds >= 1, item.firstPartialSeconds == nil {
            findings.append("\(prefix) no non-empty realtime preview was emitted")
        }
        if item.resolution != StreamingTranscriptionSession.Resolution.streamingFinalized.rawValue {
            findings.append("\(prefix) final result used `\(item.resolution ?? "unknown")`")
        }
        return findings
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", value)
    }
}

private struct WAVPayload {
    let pcmData: Data
    let durationSeconds: TimeInterval

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
            String(data: data[0..<4], encoding: .ascii) == "RIFF",
            String(data: data[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw BenchmarkError.invalidWAV(url.lastPathComponent)
        }

        var offset = 12
        var payload: Data?
        while offset + 8 <= data.count {
            let chunkName = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = Int(data[offset + 4])
                | (Int(data[offset + 5]) << 8)
                | (Int(data[offset + 6]) << 16)
                | (Int(data[offset + 7]) << 24)
            let start = offset + 8
            let end = start + size
            guard end <= data.count else { throw BenchmarkError.invalidWAV(url.lastPathComponent) }
            if chunkName == "data" {
                payload = data.subdata(in: start..<end)
                break
            }
            offset = end + (size % 2)
        }
        guard let payload else { throw BenchmarkError.invalidWAV(url.lastPathComponent) }
        pcmData = payload
        durationSeconds = Double(payload.count) / Double(16_000 * MemoryLayout<Int16>.size)
    }
}

private enum BenchmarkError: Error {
    case invalidWAV(String)
}

private struct EnhancementHarness {
    let service: AIEnhancementService
    let configuration: EnhancementRuntimeConfiguration
}

private struct CapturedText {
    let text: String?
    let error: String?
}

private struct EnhancementResult {
    let text: String?
    let error: String?
    let seconds: TimeInterval
}

private struct PartialResult: Codable {
    let seconds: TimeInterval
    let text: String
}

private struct CaseResult: Codable {
    let modelName: String
    let modelDisplayName: String
    let realtimeMode: String
    let audioFile: String
    let audioDurationSeconds: TimeInterval
    let batchText: String?
    let batchError: String?
    let batchSeconds: TimeInterval
    let batchRepeatText: String?
    let batchRepeatError: String?
    let batchRepeatSeconds: TimeInterval
    let batchRepeatSimilarity: Double?
    let streamingText: String?
    let streamingError: String?
    let streamingSeconds: TimeInterval
    let finalizeSeconds: TimeInterval
    let resolution: String?
    let firstPartialSeconds: TimeInterval?
    let partials: [PartialResult]
    let rawSimilarity: Double?
    let batchEnhancedText: String?
    let batchEnhancementError: String?
    let batchEnhancementSeconds: TimeInterval?
    let streamingEnhancedText: String?
    let streamingEnhancementError: String?
    let streamingEnhancementSeconds: TimeInterval?
    let enhancedSimilarity: Double?
}

private struct BenchmarkReport: Codable {
    let generatedAt: String
    let recordingsDirectory: String
    let audioCount: Int
    let replayedInRealtime: Bool
    let enhancementEnabled: Bool
    let enhancementProvider: String?
    let enhancementModel: String?
    let enhancementPrompt: String?
    let historicalContextIncluded: Bool
    let cases: [CaseResult]
}
