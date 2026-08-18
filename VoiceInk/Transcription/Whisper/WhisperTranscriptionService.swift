import AVFoundation
import Foundation
import os

class WhisperTranscriptionService: TranscriptionService {

    private var whisperContext: WhisperContext?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // Check if the required model is already loaded in the model provider
        if let provider = modelProvider,
            await provider.isModelLoaded,
            let loadedContext = await provider.whisperContext,
            await provider.loadedWhisperModel?.name == model.name
        {

            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            whisperContext = loadedContext
        } else {
            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        }

        guard let whisperContext = whisperContext else {
            logger.error("❌ Cannot transcribe: Model could not be loaded")
            throw VoiceInkEngineError.modelLoadFailed
        }

        // File I/O and PCM conversion can be substantial for long recordings.
        // Keep that work away from the caller's executor (normally MainActor).
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.readAudioSamples(audioURL)
        }.value

        // Set prompt
        await whisperContext.setLanguage(context.language)
        await whisperContext.setPrompt(context.prompt ?? "")

        // Transcribe
        let success = await whisperContext.fullTranscribe(samples: data)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await whisperContext.getTranscription()

        logger.notice("Whisper transcription completed successfully.")

        // Only release resources if we created a new context (not using the shared one)
        if await modelProvider?.whisperContext !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }

        return text
    }

    static func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sampleCount = (data.count - 44) / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var samples = [Float](repeating: 0, count: sampleCount)
            for sampleIndex in 0..<sampleCount {
                let byteIndex = 44 + sampleIndex * 2
                let rawSample = UInt16(bytes[byteIndex]) | (UInt16(bytes[byteIndex + 1]) << 8)
                let sample = Int16(bitPattern: rawSample)
                samples[sampleIndex] = max(-1.0, min(Float(sample) / 32767.0, 1.0))
            }
            return samples
        }
    }
}
