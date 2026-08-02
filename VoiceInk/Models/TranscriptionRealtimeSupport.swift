import Foundation

enum TranscriptionRealtimeMode: Equatable {
    case nativeStreaming
    case slidingWindow
    case batchOnly
}

enum TranscriptionRealtimeSupport {
    /// Describes how VoiceInk actually produces live text for a model.
    /// `supportsStreaming` alone cannot distinguish a native streaming path
    /// from a local model that periodically re-decodes a bounded audio window.
    static func mode(for model: any TranscriptionModel) -> TranscriptionRealtimeMode {
        guard model.supportsStreaming else { return .batchOnly }

        if model.provider == .fluidAudio {
            if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name)
                || FluidAudioModelManager.isNemotronModel(named: model.name)
            {
                return .nativeStreaming
            }

            // FluidAudio's TDT V2/V3 path uses an offline encoder over sliding
            // windows. Its CTC, SenseVoice, and Paraformer managers likewise
            // expose whole-utterance transcription rather than encoder caches.
            return .slidingWindow
        }

        if model.provider == .sherpaOnnx {
            return .slidingWindow
        }

        if model.provider == .qwenMlx {
            return .nativeStreaming
        }

        return .nativeStreaming
    }

    static func isAvailable(for model: any TranscriptionModel) -> Bool {
        model.supportsStreaming
    }

    static func isRequired(for model: any TranscriptionModel) -> Bool {
        if model.provider == .fluidAudio {
            return FluidAudioModelManager.requiresRealtime(named: model.name)
        }

        return CloudProviderRegistry.provider(for: model.provider)?.isStreamingOnly ?? false
    }

    static func isEnabled(for model: any TranscriptionModel, modeValue: Bool? = nil) -> Bool {
        guard isAvailable(for: model) else { return false }
        if isRequired(for: model) { return true }
        if let modeValue { return modeValue }
        return true
    }
}
