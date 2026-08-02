import Foundation

enum TranscriptionModelRegistry {

    static var models: [any TranscriptionModel] {
        return predefinedModels + CustomCloudModelManager.shared.customModels
    }

    private static let predefinedModels: [any TranscriptionModel] = {
        let nonCloudModels: [any TranscriptionModel] = [
            // Native Apple Model
            NativeAppleModel(
                name: "apple-speech",
                displayName: "Apple Speech",
                description: "Uses the native Apple Speech framework for transcription. Requires macOS 26",
                isMultilingualModel: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .nativeApple)
            ),

            // Parakeet Models
            FluidAudioModel(
                name: "parakeet-tdt-0.6b-v2",
                displayName: "Parakeet V2",
                description: "NVIDIA's Parakeet V2 model optimized for lightning-fast English-only transcription",
                size: "474 MB",
                speed: 0.99,
                accuracy: 0.94,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet V3",
                description: "Parakeet V3 with English and 25 European language support",
                size: "494 MB",
                speed: 0.99,
                accuracy: 0.94,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-ctc-0.6b-zh-cn",
                displayName: "Parakeet CTC 0.6B (中文)",
                description: "面向普通话和中英混合语音的本地 CTC 模型，并可通过滑动窗口实时预览",
                size: "约 610 MB",
                speed: 0.97,
                accuracy: 0.91,
                ramUsage: 1.0,
                supportsStreaming: true,
                supportedLanguages: [
                    "zh-CN": "Mandarin Chinese",
                    "en": "English",
                ]
            ),
            FluidAudioModel(
                name: "parakeet-unified-0.6b",
                displayName: "Parakeet Unified",
                description: "English-only Parakeet model with native realtime transcription support",
                size: "1.2 GB",
                speed: 0.99,
                accuracy: 0.95,
                ramUsage: 1.0,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "nemotron-latin-0.6b",
                displayName: "Nemotron Latin",
                description: "NVIDIA's Nemotron streaming model with Latin language support",
                size: "620 MB",
                speed: 0.99,
                accuracy: 0.92,
                ramUsage: 1.2,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.nemotronLatin
            ),
            FluidAudioModel(
                name: "nemotron-multilingual-0.6b",
                displayName: "Nemotron Multilingual",
                description: "NVIDIA's Nemotron streaming model with multilingual support",
                size: "672 MB",
                speed: 0.99,
                accuracy: 0.90,
                ramUsage: 1.5,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.nemotronMultilingual
            ),
            FluidAudioModel(
                name: "sensevoice-small",
                displayName: "FunASR SenseVoice Small",
                description: "支持中文、粤语、英语、日语和韩语，并可在录音中实时预览",
                size: "约 230 MB",
                speed: 0.96,
                accuracy: 0.90,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.senseVoice
            ),
            FluidAudioModel(
                name: "paraformer-large-zh",
                displayName: "FunASR Paraformer Large (中文)",
                description: "面向普通话优化，并可在录音中实时预览",
                size: "约 480 MB",
                speed: 0.95,
                accuracy: 0.93,
                ramUsage: 1.0,
                supportsStreaming: true,
                supportedLanguages: ["zh-CN": "Mandarin Chinese"]
            ),
            SherpaOnnxModel(
                name: "qwen3-asr-0.6b-int8",
                displayName: "Qwen3-ASR 0.6B (INT8)",
                description: "Qwen3-ASR 的 sherpa-onnx 本地量化版本，支持中文、方言、多语言及实时预览",
                size: "838 MB",
                // Latest-10 local benchmark: 0.322 s median warm batch,
                // 0.610 s first preview, 0.328 s finalize. This is comparable
                // overall to the Chinese Parakeet CTC model rated at 9.7.
                speed: 0.97,
                archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2")!,
                archiveSHA256: "393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96",
                extractedDirectoryName: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
                kind: .qwen3Asr,
                supportedLanguages: LanguageDictionary.qwen3ASR
            ),
            QwenMLXModel(
                name: "qwen3-asr-0.6b-mlx-streaming",
                displayName: "Qwen3-ASR 0.6B (MLX Streaming)",
                description: "Apple Silicon Metal GPU 原生流式版本，支持中英等 30 种语言及 22 种中文方言；增量解码复用 KV Cache",
                size: "约 1.9 GB + 运行时",
                // M4 Max local benchmark: 0.269 s median warm batch and
                // 7.3x realtime native streaming throughput.
                speed: 0.95,
                // Local 2-second energy-endpointed stream/batch consistency.
                // The card labels this separately from upstream WER.
                accuracy: 0.90,
                repositoryID: "Qwen/Qwen3-ASR-0.6B",
                revision: "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
                supportedLanguages: LanguageDictionary.qwen3ASR
            ),
            SherpaOnnxModel(
                name: "sherpa-zipformer-ctc-zh-int8",
                displayName: "sherpa-onnx Zipformer CTC (中文)",
                description: "轻量、快速的中文 Zipformer CTC 本地语音识别模型",
                size: "287 MB",
                speed: 0.98,
                archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-ctc-zh-int8-2025-07-03.tar.bz2")!,
                archiveSHA256: "f3ad1814fea34c407eab0cc3df6f6b625419ac9a60d8aebd8efe772a8e85ef67",
                extractedDirectoryName: "sherpa-onnx-zipformer-ctc-zh-int8-2025-07-03",
                kind: .zipformerCtc,
                supportedLanguages: ["zh-CN": "Mandarin Chinese"]
            ),

            // Local Models
            WhisperModel(
                name: "ggml-tiny",
                displayName: "Tiny",
                size: "75 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Tiny model, fastest, least accurate",
                speed: 0.95,
                accuracy: 0.6,
                ramUsage: 0.3
            ),
            WhisperModel(
                name: "ggml-tiny.en",
                displayName: "Tiny (English)",
                size: "75 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .whisper),
                description: "Tiny model optimized for English, fastest, least accurate",
                speed: 0.95,
                accuracy: 0.65,
                ramUsage: 0.3
            ),
            WhisperModel(
                name: "ggml-base",
                displayName: "Base",
                size: "142 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Base model, good balance between speed and accuracy, supports multiple languages",
                speed: 0.85,
                accuracy: 0.72,
                ramUsage: 0.5
            ),
            WhisperModel(
                name: "ggml-base.en",
                displayName: "Base (English)",
                size: "142 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .whisper),
                description: "Base model optimized for English, good balance between speed and accuracy",
                speed: 0.85,
                accuracy: 0.75,
                ramUsage: 0.5
            ),
            WhisperModel(
                name: "ggml-small",
                displayName: "Small（支持中文）",
                size: "466 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "兼顾速度与中文识别质量的 Whisper 多语言模型",
                speed: 0.68,
                accuracy: 0.84,
                ramUsage: 0.9
            ),
            WhisperModel(
                name: "ggml-medium",
                displayName: "Medium（支持中文）",
                size: "1.5 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "中文准确率更高的 Whisper 多语言模型",
                speed: 0.48,
                accuracy: 0.91,
                ramUsage: 2.2
            ),
            WhisperModel(
                name: "ggml-large-v2",
                displayName: "Large v2",
                size: "2.9 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Large model v2, slower than Medium but more accurate",
                speed: 0.3,
                accuracy: 0.95,
                ramUsage: 3.8
            ),
            WhisperModel(
                name: "ggml-large-v3",
                displayName: "Large v3",
                size: "2.9 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Large model v3, very slow but most accurate",
                speed: 0.3,
                accuracy: 0.95,
                ramUsage: 3.9
            ),
            WhisperModel(
                name: "ggml-large-v3-turbo",
                displayName: "Large v3 Turbo",
                size: "1.5 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Large model v3 Turbo, faster than v3 with similar accuracy",
                speed: 0.75,
                accuracy: 0.94,
                ramUsage: 1.8
            ),
            WhisperModel(
                name: "ggml-large-v3-turbo-q5_0",
                displayName: "Large v3 Turbo (Quantized)",
                size: "547 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Quantized version of Large v3 Turbo, faster with slightly lower accuracy",
                speed: 0.75,
                accuracy: 0.94,
                ramUsage: 1.0
            ),
        ]

        let cloudModels: [any TranscriptionModel] = CloudProviderRegistry.allProviders.flatMap { $0.models }
        return nonCloudModels + cloudModels
    }()
}
