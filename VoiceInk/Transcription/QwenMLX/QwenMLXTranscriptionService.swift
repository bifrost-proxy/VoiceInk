import Foundation

actor QwenMLXTranscriptionService: TranscriptionService {
    private let runtime: QwenMLXRuntime

    init(runtime: QwenMLXRuntime = .shared) {
        self.runtime = runtime
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let model = model as? QwenMLXModel else {
            throw QwenMLXTranscriptionError.invalidModel
        }
        guard await QwenMLXModelManager.shared.isReady(model) else {
            throw QwenMLXTranscriptionError.modelNotInstalled
        }

        _ = try await runtime.load(model: model)
        let text = try await runtime.transcribe(
            audioURL: audioURL,
            language: context.language,
            context: context.prompt
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum QwenMLXTranscriptionError: LocalizedError {
    case invalidModel
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .invalidModel:
            return "Invalid Qwen MLX model"
        case .modelNotInstalled:
            return "模型或 MLX 运行时尚未下载，请先在“AI 模型”中安装"
        }
    }
}
