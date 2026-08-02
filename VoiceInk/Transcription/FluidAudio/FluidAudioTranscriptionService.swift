import FluidAudio
import Foundation
import os.log

/// FluidAudio's offline FunASR managers share mutable Core ML inference state.
/// Keep inference calls serialized so app-launch prewarming cannot overlap the
/// first realtime preview and corrupt either result.
private actor FunASRInferenceGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

class FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var senseVoiceManager: SenseVoiceManager?
    private var paraformerManager: ParaformerManager?
    private var parakeetCtcZhCnManager: ParakeetCtcZhCnManager?
    private var senseVoiceLoadingTask: Task<SenseVoiceManager, Error>?
    private var paraformerLoadingTask: Task<ParaformerManager, Error>?
    private var parakeetCtcZhCnLoadingTask: Task<ParakeetCtcZhCnManager, Error>?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioTranscriptionService")
    private static let senseVoiceTrailingSilenceSamples = 8_000
    private static let funASRInferenceGate = FunASRInferenceGate()

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers() async {
        senseVoiceLoadingTask?.cancel()
        paraformerLoadingTask?.cancel()
        parakeetCtcZhCnLoadingTask?.cancel()
        senseVoiceLoadingTask = nil
        paraformerLoadingTask = nil
        parakeetCtcZhCnLoadingTask = nil

        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        senseVoiceManager = nil
        paraformerManager = nil
        parakeetCtcZhCnManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    private func ensureSenseVoiceLoaded() async throws {
        if senseVoiceManager != nil { return }
        if let senseVoiceLoadingTask {
            senseVoiceManager = try await senseVoiceLoadingTask.value
            return
        }
        await cleanupLoadedManagers()
        let task = Task {
            let models = try SenseVoiceModels.load(
                from: FluidAudioModelManager.senseVoiceCacheDirectory(), precision: .int8)
            return SenseVoiceManager(models: models)
        }
        senseVoiceLoadingTask = task
        do {
            senseVoiceManager = try await task.value
            senseVoiceLoadingTask = nil
        } catch {
            senseVoiceLoadingTask = nil
            throw error
        }
    }

    private func ensureParaformerLoaded() async throws {
        if paraformerManager != nil { return }
        if let paraformerLoadingTask {
            paraformerManager = try await paraformerLoadingTask.value
            return
        }
        await cleanupLoadedManagers()
        let task = Task {
            let models = try ParaformerModels.load(
                from: FluidAudioModelManager.paraformerZhCacheDirectory(), precision: .int8)
            return ParaformerManager(models: models)
        }
        paraformerLoadingTask = task
        do {
            paraformerManager = try await task.value
            paraformerLoadingTask = nil
        } catch {
            paraformerLoadingTask = nil
            throw error
        }
    }

    private func ensureParakeetCtcZhCnLoaded() async throws {
        if parakeetCtcZhCnManager != nil { return }
        if let parakeetCtcZhCnLoadingTask {
            parakeetCtcZhCnManager = try await parakeetCtcZhCnLoadingTask.value
            return
        }

        await cleanupLoadedManagers()
        let task = Task {
            try ParakeetCtcZhCnManager.load(
                from: FluidAudioModelManager.parakeetCtcZhCnCacheDirectory()
            )
        }
        parakeetCtcZhCnLoadingTask = task
        do {
            parakeetCtcZhCnManager = try await task.value
            parakeetCtcZhCnLoadingTask = nil
        } catch {
            parakeetCtcZhCnLoadingTask = nil
            throw error
        }
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: cacheDirectory, version: version) else {
                throw AsrModelsError.loadingFailed(
                    "Parakeet model files are incomplete. Download the model from AI Models."
                )
            }
            return try await AsrModels.load(
                from: cacheDirectory,
                configuration: nil,
                version: version,
                encoderPrecision: .int8
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isParakeetCtcZhCnModel(named: model.name) {
            try await ensureParakeetCtcZhCnLoaded()
            return
        }
        if FluidAudioModelManager.isSenseVoiceModel(named: model.name) {
            try await ensureSenseVoiceLoaded()
            return
        }
        if FluidAudioModelManager.isParaformerZhModel(named: model.name) {
            try await ensureParaformerLoaded()
            return
        }
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        if FluidAudioModelManager.isParakeetCtcZhCnModel(named: model.name) {
            try await ensureParakeetCtcZhCnLoaded()
            let samples = try loadAudioSamples(from: audioURL)
            return try await transcribeParakeetCtcZhCnLongForm(samples)
        }

        if FluidAudioModelManager.isSenseVoiceModel(named: model.name) {
            try await ensureSenseVoiceLoaded()
            guard let senseVoiceManager else { throw ASRError.notInitialized }
            let samples = try loadAudioSamples(from: audioURL)
            let preparedSamples = Self.prepareSenseVoiceSamples(samples)
            let text = try await Self.funASRInferenceGate.perform {
                try await senseVoiceManager.transcribe(audio: preparedSamples)
            }
            return TextNormalizer.shared.normalizeSentence(text)
        }

        if FluidAudioModelManager.isParaformerZhModel(named: model.name) {
            try await ensureParaformerLoaded()
            guard let paraformerManager else { throw ASRError.notInitialized }
            let text = try await Self.funASRInferenceGate.perform {
                try await paraformerManager.transcribe(audioURL: audioURL)
            }
            return TextNormalizer.shared.normalizeSentence(text)
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try loadAudioSamples(from: audioURL)
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return TextNormalizer.shared.normalizeSentence(text)
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try loadAudioSamples(from: audioURL)
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return TextNormalizer.shared.normalizeSentence(text)
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: languageHint
        )

        return TextNormalizer.shared.normalizeSentence(result.text)
    }

    func prepareBufferedStreamingPreview(named modelName: String) async throws {
        if FluidAudioModelManager.isParakeetCtcZhCnModel(named: modelName) {
            try await ensureParakeetCtcZhCnLoaded()
            return
        }
        if FluidAudioModelManager.isSenseVoiceModel(named: modelName) {
            try await ensureSenseVoiceLoaded()
            return
        }
        if FluidAudioModelManager.isParaformerZhModel(named: modelName) {
            try await ensureParaformerLoaded()
            return
        }
        throw ASRError.processingFailed("Unsupported buffered FluidAudio model: \(modelName)")
    }

    func transcribeBufferedStreamingPreview(samples: [Float], modelName: String) async throws -> String {
        if FluidAudioModelManager.isParakeetCtcZhCnModel(named: modelName) {
            try await ensureParakeetCtcZhCnLoaded()
            return try await transcribeParakeetCtcZhCnLongForm(samples)
        }
        if FluidAudioModelManager.isSenseVoiceModel(named: modelName) {
            try await ensureSenseVoiceLoaded()
            guard let senseVoiceManager else { throw ASRError.notInitialized }
            let preparedSamples = Self.prepareSenseVoiceSamples(samples)
            let text = try await Self.funASRInferenceGate.perform {
                try await senseVoiceManager.transcribe(audio: preparedSamples)
            }
            return TextNormalizer.shared.normalizeSentence(text)
        }
        if FluidAudioModelManager.isParaformerZhModel(named: modelName) {
            try await ensureParaformerLoaded()
            guard let paraformerManager else { throw ASRError.notInitialized }
            let text = try await Self.funASRInferenceGate.perform {
                try await paraformerManager.transcribe(audio: samples)
            }
            return TextNormalizer.shared.normalizeSentence(text)
        }
        throw ASRError.processingFailed("Unsupported buffered FluidAudio model: \(modelName)")
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    private func transcribeParakeetCtcZhCnLongForm(_ samples: [Float]) async throws -> String {
        guard let parakeetCtcZhCnManager else { throw ASRError.notInitialized }

        let windowSamples = 240_000
        let overlapSamples = 16_000
        guard samples.count > windowSamples else {
            let text = try await parakeetCtcZhCnManager.transcribe(audio: samples)
            return TextNormalizer.shared.normalizeSentence(text)
        }

        var assembler = IncrementalTranscriptAssembler()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + windowSamples, samples.count)
            let text = try await parakeetCtcZhCnManager.transcribe(
                audio: Array(samples[offset..<end])
            )
            _ = assembler.finalize(TextNormalizer.shared.normalizeSentence(text))
            guard end < samples.count else { break }
            offset = end - overlapSamples
        }
        return assembler.finalizedText
    }

    static func prepareSenseVoiceSamples(_ samples: [Float]) -> [Float] {
        samples + [Float](repeating: 0, count: senseVoiceTrailingSilenceSamples)
    }

    // Releases ASR resources but preserves cached models for reuse
    func cleanup() async {
        await cleanupLoadedManagers()
    }

}
