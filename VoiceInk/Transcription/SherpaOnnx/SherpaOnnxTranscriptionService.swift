import FluidAudio
import Foundation
import SherpaOnnx

actor SherpaOnnxTranscriptionService: TranscriptionService {
    private let audioConverter = AudioConverter(sampleRate: 16_000)

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let model = model as? SherpaOnnxModel else {
            throw ASRError.processingFailed("Invalid sherpa-onnx model")
        }
        let directory = await SherpaOnnxModelManager.shared.modelDirectory(for: model)
        guard await SherpaOnnxModelManager.shared.isDownloaded(model) else {
            throw ASRError.processingFailed("模型尚未下载，请先在“AI 模型”中下载")
        }

        let recognizer: SherpaOnnxOfflineRecognizer
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
                tokens: "", numThreads: 4, provider: "cpu", qwen3Asr: qwen3)
            let featureConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
            var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
                featConfig: featureConfig, modelConfig: modelConfig)
            recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
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
            recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
        }
        let samples = try audioConverter.resampleAudioFile(audioURL)
        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        return TextNormalizer.shared.normalizeSentence(result.text)
    }
}
