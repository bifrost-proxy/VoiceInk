import Combine
import Foundation

@MainActor
final class WhisperModelWarmupCoordinator: ObservableObject {
    static let shared = WhisperModelWarmupCoordinator()

    @Published private(set) var warmingModels: Set<String> = []
    private let warmupTasks = ModelPrewarmTaskRegistry()
    private var isSuspendedForRuntimePressure = false

    private init() {}

    func isWarming(modelNamed name: String) -> Bool {
        warmingModels.contains(name)
    }

    func scheduleWarmup(for model: WhisperModel, whisperModelManager: WhisperModelManager) {
        guard !isSuspendedForRuntimePressure,
            shouldWarmup(modelName: model.name),
            !warmingModels.contains(model.name)
        else {
            return
        }

        warmingModels.insert(model.name)

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishWarmup(taskID: taskID, modelName: model.name) }
            guard await RuntimePressureOperationCoordinator.shared.beginOperation() else { return }
            defer { RuntimePressureOperationCoordinator.shared.endOperation() }
            let operationID = RuntimeProtectedWorkActivity.shared.begin()
            defer { RuntimeProtectedWorkActivity.shared.end(operationID) }
            do {
                try await runWarmup(for: model, whisperModelManager: whisperModelManager)
            } catch {
                await MainActor.run {
                    whisperModelManager.logger.error(
                        "❌ Warmup failed for \(model.name, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
        warmupTasks.insert(task, id: taskID)
    }

    func suspendForRuntimePressure() async {
        isSuspendedForRuntimePressure = true
        let tasksToStop = warmupTasks.cancelAll()
        for task in tasksToStop {
            await task.value
        }
    }

    func resumeAfterRuntimePressure() {
        isSuspendedForRuntimePressure = false
    }

    private func finishWarmup(taskID: UUID, modelName: String) {
        warmupTasks.remove(id: taskID)
        warmingModels.remove(modelName)
    }

    private func runWarmup(for model: WhisperModel, whisperModelManager: WhisperModelManager) async throws {
        guard let sampleURL = warmupSampleURL() else { return }
        let service = WhisperTranscriptionService(
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelProvider: whisperModelManager
        )
        _ = try await service.transcribe(audioURL: sampleURL, model: model)
    }

    private func warmupSampleURL() -> URL? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "sound7", withExtension: "wav", subdirectory: "Resources/Sounds"),
            bundle.url(forResource: "sound7", withExtension: "wav", subdirectory: "Sounds"),
            bundle.url(forResource: "sound7", withExtension: "wav"),
        ]

        for candidate in candidates {
            if let url = candidate {
                return url
            }
        }

        return nil
    }

    private func shouldWarmup(modelName: String) -> Bool {
        !modelName.contains("q5") && !modelName.contains("q8")
    }
}
