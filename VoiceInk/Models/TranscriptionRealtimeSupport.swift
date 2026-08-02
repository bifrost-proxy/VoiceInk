import Foundation

enum TranscriptionRealtimeMode: Equatable {
    case continuousStreaming
    case slidingWindow
    case batchOnly
}

enum TranscriptionRealtimeSupport {
    /// Describes how VoiceInk actually produces live text for a model.
    /// `supportsStreaming` alone cannot distinguish a continuous streaming decoder
    /// from a local model that periodically re-decodes a bounded audio window.
    static func mode(for model: any TranscriptionModel) -> TranscriptionRealtimeMode {
        guard model.supportsStreaming else { return .batchOnly }

        if model.provider == .fluidAudio {
            if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name)
                || FluidAudioModelManager.isNemotronModel(named: model.name)
            {
                return .continuousStreaming
            }

            return .slidingWindow
        }

        if model.provider == .sherpaOnnx {
            return .slidingWindow
        }

        return .continuousStreaming
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
