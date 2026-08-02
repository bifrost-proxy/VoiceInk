import Foundation

// Enum to differentiate between model providers
enum ModelProvider: String, Codable, Hashable, CaseIterable {
    case whisper = "Whisper"
    case fluidAudio = "Parakeet"
    case sherpaOnnx = "sherpa-onnx"
    case qwenMlx = "Qwen MLX"
    case groq = "Groq"
    case elevenLabs = "ElevenLabs"
    case deepgram = "Deepgram"
    case mistral = "Mistral"
    case gemini = "Gemini"
    case soniox = "Soniox"
    case speechmatics = "Speechmatics"
    case assemblyAI = "AssemblyAI"
    case xai = "xAI"
    case cartesia = "Cartesia"
    case custom = "Custom"
    case nativeApple = "Native Apple"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // "Local" was the raw value before renaming to "Whisper"
        if raw == "Local" {
            self = .whisper
            return
        }
        guard let value = ModelProvider(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ModelProvider: \(raw)")
        }
        self = value
    }
}

// A unified protocol for any transcription model
protocol TranscriptionModel: Identifiable, Hashable {
    var id: UUID { get }
    var name: String { get }
    var displayName: String { get }
    var description: String { get }
    var provider: ModelProvider { get }

    // Language capabilities
    var isMultilingualModel: Bool { get }
    var supportedLanguages: [String: String] { get }

    var supportsStreaming: Bool { get }
    var officialSourceURL: URL? { get }
}

extension TranscriptionModel {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var language: String {
        if isMultilingualModel {
            return String(localized: "Multilingual")
        }
        if let languageCode = supportedLanguages.keys.first,
            !languageCode.lowercased().hasPrefix("en")
        {
            return supportedLanguages[languageCode] ?? languageCode
        }
        return String(localized: "English")
    }

    var supportsStreaming: Bool { false }

    var officialSourceURL: URL? {
        ModelOfficialSourceCatalog.url(for: self)
    }
}

/// Official model pages for the downloadable models bundled with VoiceInk.
///
/// These URLs intentionally point to the original model author or the official
/// distributor of the exact converted artifact, never to an unrelated mirror.
enum ModelOfficialSourceCatalog {
    private static let sourceURLsByModelName: [String: String] = [
        "parakeet-tdt-0.6b-v2": "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2",
        "parakeet-tdt-0.6b-v3": "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
        "parakeet-ctc-0.6b-zh-cn": "https://huggingface.co/FluidInference/parakeet-ctc-0.6b-zh-cn-coreml",
        "parakeet-unified-0.6b": "https://huggingface.co/nvidia/parakeet-unified-en-0.6b",
        "nemotron-latin-0.6b": "https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b",
        "nemotron-multilingual-0.6b": "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b",
        "sensevoice-small": "https://huggingface.co/FunAudioLLM/SenseVoiceSmall",
        "paraformer-large-zh": "https://modelscope.cn/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "qwen3-asr-0.6b-int8": "https://huggingface.co/Qwen/Qwen3-ASR-0.6B",
        "qwen3-asr-0.6b-mlx-streaming": "https://huggingface.co/Qwen/Qwen3-ASR-0.6B",
        "sherpa-zipformer-ctc-zh-int8": "https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-ctc/icefall/zipformer.html",
    ]

    private static let whisperSourceURL = URL(string: "https://github.com/openai/whisper")

    static func url(for model: any TranscriptionModel) -> URL? {
        if let urlString = sourceURLsByModelName[model.name] {
            return URL(string: urlString)
        }

        if model.provider == .whisper, model is WhisperModel {
            return whisperSourceURL
        }

        return nil
    }
}

// A new struct for Apple's native models
struct NativeAppleModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .nativeApple
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]
}

// A new struct for FluidAudio models
struct FluidAudioModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .fluidAudio
    let size: String
    let speed: Double
    let accuracy: Double
    let ramUsage: Double
    let supportsStreaming: Bool
    var isMultilingualModel: Bool {
        supportedLanguages.count > 1
    }
    let supportedLanguages: [String: String]

    init(
        name: String, displayName: String, description: String, size: String, speed: Double, accuracy: Double,
        ramUsage: Double, supportsStreaming: Bool = false, supportedLanguages: [String: String]
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.size = size
        self.speed = speed
        self.accuracy = accuracy
        self.ramUsage = ramUsage
        self.supportsStreaming = supportsStreaming
        self.supportedLanguages = supportedLanguages
    }
}

enum SherpaOnnxModelKind: String, Hashable {
    case qwen3Asr
    case zipformerCtc
}

struct SherpaOnnxModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .sherpaOnnx
    let size: String
    let speed: Double
    let archiveURL: URL
    let archiveSHA256: String
    let extractedDirectoryName: String
    let kind: SherpaOnnxModelKind
    let supportedLanguages: [String: String]
    var supportsStreaming: Bool { kind == .qwen3Asr }
    var accuracy: Double? { kind == .qwen3Asr ? 0.96 : nil }

    var isMultilingualModel: Bool { supportedLanguages.count > 1 }
}

/// Qwen3-ASR running through the MLX Metal backend on Apple Silicon.
///
/// This is intentionally a separate provider from the sherpa-onnx INT8 model:
/// the latter remains a CPU sliding-window implementation, while this provider
/// owns an incremental decoder state and reuses its KV cache between chunks.
struct QwenMLXModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .qwenMlx
    let size: String
    let speed: Double
    /// Product-facing integration consistency score from VoiceInk's local
    /// streaming benchmark. This is not presented as an upstream WER/CER.
    let accuracy: Double
    let repositoryID: String
    let revision: String
    let supportedLanguages: [String: String]
    let supportsStreaming = true

    var isMultilingualModel: Bool { supportedLanguages.count > 1 }
}

// A new struct for cloud models
struct CloudModel: TranscriptionModel {
    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider
    let speed: Double
    let accuracy: Double
    let isMultilingualModel: Bool
    let supportsStreaming: Bool
    let supportedLanguages: [String: String]

    init(
        id: UUID = UUID(), name: String, displayName: String, description: String, provider: ModelProvider,
        speed: Double, accuracy: Double, isMultilingual: Bool, supportsStreaming: Bool = false,
        supportedLanguages: [String: String]
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.provider = provider
        self.speed = speed
        self.accuracy = accuracy
        self.isMultilingualModel = isMultilingual
        self.supportsStreaming = supportsStreaming
        self.supportedLanguages = supportedLanguages
    }
}

/// Custom cloud model with API key stored in Keychain.
struct CustomCloudModel: TranscriptionModel, Codable {
    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .custom
    let apiEndpoint: String
    let modelName: String
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]

    /// API key retrieved from Keychain by model ID.
    var apiKey: String {
        APIKeyManager.shared.getCustomModelAPIKey(forModelId: id) ?? ""
    }

    init(
        id: UUID = UUID(), name: String, displayName: String, description: String, apiEndpoint: String,
        modelName: String, isMultilingual: Bool = true, supportedLanguages: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.apiEndpoint = apiEndpoint
        self.modelName = modelName
        self.isMultilingualModel = isMultilingual
        self.supportedLanguages = supportedLanguages ?? LanguageDictionary.forProvider(isMultilingual: isMultilingual)
    }

    /// Custom Codable to migrate legacy apiKey from JSON to Keychain.
    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, apiEndpoint, modelName, isMultilingualModel, supportedLanguages
        case apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        apiEndpoint = try container.decode(String.self, forKey: .apiEndpoint)
        modelName = try container.decode(String.self, forKey: .modelName)
        isMultilingualModel = try container.decode(Bool.self, forKey: .isMultilingualModel)
        supportedLanguages = try container.decode([String: String].self, forKey: .supportedLanguages)

        if let legacyApiKey = try container.decodeIfPresent(String.self, forKey: .apiKey), !legacyApiKey.isEmpty {
            APIKeyManager.shared.saveCustomModelAPIKey(legacyApiKey, forModelId: id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(apiEndpoint, forKey: .apiEndpoint)
        try container.encode(modelName, forKey: .modelName)
        try container.encode(isMultilingualModel, forKey: .isMultilingualModel)
        try container.encode(supportedLanguages, forKey: .supportedLanguages)
    }
}

struct WhisperModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let size: String
    let supportedLanguages: [String: String]
    let description: String
    let speed: Double
    let accuracy: Double
    let ramUsage: Double
    let provider: ModelProvider = .whisper

    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
    }

    var filename: String {
        "\(name).bin"
    }

    var isMultilingualModel: Bool {
        supportedLanguages.count > 1
    }
}

// User-imported local models
struct ImportedWhisperModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .whisper
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]

    init(fileBaseName: String) {
        self.name = fileBaseName
        self.displayName = fileBaseName
        self.description = "Imported local model"
        self.isMultilingualModel = true
        self.supportedLanguages = LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper)
    }
}
