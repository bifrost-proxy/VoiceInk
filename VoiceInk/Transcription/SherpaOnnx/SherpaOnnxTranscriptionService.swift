import FluidAudio
import Foundation
import SherpaOnnx

actor SherpaOnnxTranscriptionService: TranscriptionService {
    nonisolated static let qwenCPUProviderConfigResourceName = "qwen-onnxruntime-cpu"
    private let audioConverter = AudioConverter(sampleRate: 16_000)
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var activeModelName: String?

    nonisolated static func qwenCPUProvider(bundle: Bundle = .main) throws -> String {
        guard
            let configURL = bundle.url(
                forResource: qwenCPUProviderConfigResourceName,
                withExtension: "conf"
            )
        else {
            throw ASRError.processingFailed(
                "Qwen3-ASR CPU runtime configuration is missing from the application bundle"
            )
        }

        return "cpu:\(configURL.path)"
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let model = model as? SherpaOnnxModel else {
            throw ASRError.processingFailed("Invalid sherpa-onnx model")
        }
        let recognizer = try await recognizer(for: model)
        let samples = try audioConverter.resampleAudioFile(audioURL)
        return decode(samples: samples, using: recognizer)
    }

    func prepareBufferedStreamingPreview(named modelName: String) async throws {
        guard let model = registeredModel(named: modelName), model.kind == .qwen3Asr else {
            throw ASRError.processingFailed("Unsupported buffered sherpa-onnx model: \(modelName)")
        }
        _ = try await recognizer(for: model)
    }

    func transcribeBufferedStreamingPreview(samples: [Float], modelName: String) async throws -> String {
        guard let model = registeredModel(named: modelName), model.kind == .qwen3Asr else {
            throw ASRError.processingFailed("Unsupported buffered sherpa-onnx model: \(modelName)")
        }
        let recognizer = try await recognizer(for: model)
        return decode(samples: samples, using: recognizer)
    }

    private func registeredModel(named modelName: String) -> SherpaOnnxModel? {
        TranscriptionModelRegistry.models.first { $0.name == modelName } as? SherpaOnnxModel
    }

    private func recognizer(for model: SherpaOnnxModel) async throws -> SherpaOnnxOfflineRecognizer {
        if let recognizer, activeModelName == model.name {
            return recognizer
        }

        let directory = await SherpaOnnxModelManager.shared.modelDirectory(for: model)
        guard await SherpaOnnxModelManager.shared.isDownloaded(model) else {
            throw ASRError.processingFailed("模型尚未下载，请先在“AI 模型”中下载")
        }

        let loadedRecognizer: SherpaOnnxOfflineRecognizer
        switch model.kind {
        case .qwen3Asr:
            let qwen3 = sherpaOnnxOfflineQwen3ASRModelConfig(
                convFrontend: directory.appendingPathComponent("conv_frontend.onnx").path,
                encoder: directory.appendingPathComponent("encoder.int8.onnx").path,
                decoder: directory.appendingPathComponent("decoder.int8.onnx").path,
                tokenizer: directory.appendingPathComponent("tokenizer").path,
                maxTotalLen: 512,
                maxNewTokens: 256
            )
            let modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: 4,
                provider: try Self.qwenCPUProvider(),
                qwen3Asr: qwen3
            )
            let featureConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
            var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
                featConfig: featureConfig, modelConfig: modelConfig)
            loadedRecognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
        case .zipformerCtc:
            let zipformer = sherpaOnnxOfflineZipformerCtcModelConfig(
                model: directory.appendingPathComponent("model.int8.onnx").path)
            let modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: directory.appendingPathComponent("tokens.txt").path,
                numThreads: 4,
                provider: "cpu",
                zipformerCtc: zipformer
            )
            let featureConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
            var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
                featConfig: featureConfig, modelConfig: modelConfig)
            loadedRecognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
        }

        recognizer = loadedRecognizer
        activeModelName = model.name
        return loadedRecognizer
    }

    func releaseResourcesIfUnbound(boundModelNames: Set<String>) -> String? {
        guard let activeModelName, !boundModelNames.contains(activeModelName) else {
            return nil
        }
        recognizer = nil
        self.activeModelName = nil
        return activeModelName
    }

    func releaseAllResources() -> String? {
        guard let activeModelName else { return nil }
        recognizer = nil
        self.activeModelName = nil
        return activeModelName
    }

    private func decode(samples: [Float], using recognizer: SherpaOnnxOfflineRecognizer) -> String {
        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        return TextNormalizer.shared.normalizeSentence(result.text)
    }
}
