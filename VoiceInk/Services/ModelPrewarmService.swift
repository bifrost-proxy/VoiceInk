import AppKit
import Foundation
import SwiftData
import os

enum ModelPrewarmPolicy {
    static func isLocalProvider(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .whisper, .fluidAudio, .sherpaOnnx, .qwenMlx:
            return true
        default:
            return false
        }
    }

    static func shouldRun(
        isEnabled: Bool,
        isRecordingActive: Bool,
        isUnderRuntimePressure: Bool = false,
        provider: ModelProvider
    ) -> Bool {
        isEnabled && !isRecordingActive && !isUnderRuntimePressure && isLocalProvider(provider)
    }
}

@MainActor
final class ModelPrewarmTaskRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var count: Int { tasks.count }
    var isEmpty: Bool { tasks.isEmpty }

    func insert(_ task: Task<Void, Never>, id: UUID) {
        tasks[id] = task
    }

    func remove(id: UUID) {
        tasks.removeValue(forKey: id)
    }

    @discardableResult
    func cancelAll() -> [Task<Void, Never>] {
        let outstandingTasks = Array(tasks.values)
        outstandingTasks.forEach { $0.cancel() }
        return outstandingTasks
    }
}

@MainActor
final class ModelPrewarmService: ObservableObject {
    private let transcriptionModelManager: TranscriptionModelManager
    private let serviceRegistry: TranscriptionServiceRegistry
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ModelPrewarm")
    private let prewarmAudioURL = Bundle.main.url(forResource: "sound7", withExtension: "wav")
    private let prewarmEnabledKey = "PrewarmModelOnWake"
    private let prewarmTasks = ModelPrewarmTaskRegistry()
    private var recordingObserver: NSObjectProtocol?
    private var isSuspendedForRuntimePressure = false

    init(
        transcriptionModelManager: TranscriptionModelManager,
        serviceRegistry: TranscriptionServiceRegistry
    ) {
        self.transcriptionModelManager = transcriptionModelManager
        self.serviceRegistry = serviceRegistry
        setupNotifications()
        schedulePrewarmOnAppLaunch()
    }

    // MARK: - Notification Setup

    private func setupNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        // Trigger on wake from sleep
        center.addObserver(
            self,
            selector: #selector(schedulePrewarm),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        recordingObserver = NotificationCenter.default.addObserver(
            forName: .recordingDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPrewarmForRecording()
            }
        }

        logger.notice("ModelPrewarmService initialized - listening for wake and app launch")
    }

    // MARK: - Trigger Handlers

    /// Trigger on app launch (cold start)
    private func schedulePrewarmOnAppLaunch() {
        logger.notice("App launched, scheduling prewarm")
        schedulePrewarmTask()
    }

    /// Trigger on wake from sleep or screen unlock
    @objc private func schedulePrewarm() {
        logger.notice("Mac activity detected (wake/unlock), scheduling prewarm")
        schedulePrewarmTask()
    }

    private func schedulePrewarmTask() {
        guard !isSuspendedForRuntimePressure else {
            logger.notice("Skipping model prewarm scheduling while runtime pressure is active")
            return
        }
        prewarmTasks.cancelAll()
        let taskID = UUID()
        let task = Task { [weak self] in
            defer { self?.finishPrewarmTask(taskID) }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let operationID = RuntimeProtectedWorkActivity.shared.begin()
            defer { RuntimeProtectedWorkActivity.shared.end(operationID) }
            await self.performPrewarm()
        }
        prewarmTasks.insert(task, id: taskID)
    }

    private func finishPrewarmTask(_ taskID: UUID) {
        prewarmTasks.remove(id: taskID)
        if isSuspendedForRuntimePressure, prewarmTasks.isEmpty {
            logger.notice("Model prewarm termination confirmed after runtime-pressure cancellation")
        }
    }

    private func cancelPrewarmForRecording() {
        guard !prewarmTasks.isEmpty else { return }
        prewarmTasks.cancelAll()
        logger.notice("Cancelled model prewarm because recording started")
    }

    func suspendForRuntimePressure() async {
        isSuspendedForRuntimePressure = true
        let tasksToStop = prewarmTasks.cancelAll()
        // Some local runtimes perform synchronous inference and cannot observe
        // Swift task cancellation immediately. Retain and await every task,
        // including cancelled tasks superseded by a later wake/recovery, so
        // suspension is not reported until all inference has actually returned.
        logger.notice("Requested model prewarm cancellation because runtime pressure increased")
        for task in tasksToStop {
            await task.value
        }
        logger.notice("Model prewarm is quiescent under runtime pressure")
    }

    func resumeAfterRuntimePressure() {
        guard isSuspendedForRuntimePressure else { return }
        isSuspendedForRuntimePressure = false
        logger.notice("Model prewarm runtime-pressure suspension cleared")
    }

    func recoverAfterRuntimeInterruption() {
        guard !isSuspendedForRuntimePressure else {
            logger.notice("Deferring model prewarm recovery while runtime pressure is active")
            return
        }
        logger.notice("Scheduling model prewarm after runtime recovery")
        schedulePrewarmTask()
    }

    // MARK: - Core Prewarming Logic

    private func performPrewarm() async {
        guard shouldPrewarm() else { return }
        guard !Task.isCancelled else { return }

        guard let audioURL = prewarmAudioURL else {
            logger.error("❌ Prewarm audio file (sound7.wav) not found")
            return
        }

        guard
            let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )
        else {
            logger.notice("No model selected, skipping prewarm")
            return
        }
        let currentModel = transcriptionConfiguration.model

        logger.notice("Prewarming \(currentModel.displayName, privacy: .public)")
        let startTime = Date()

        do {
            let _ = try await serviceRegistry.transcribe(
                audioURL: audioURL,
                model: currentModel,
                context: transcriptionConfiguration.requestContext
            )
            guard !Task.isCancelled else {
                logger.notice("Model prewarm stopped for an active recording")
                return
            }
            let duration = Date().timeIntervalSince(startTime)

            logger.notice("Prewarm completed in \(String(format: "%.2f", duration), privacy: .public)s")

        } catch where Task.isCancelled {
            logger.notice("Model prewarm cancelled")
        } catch {
            logger.error("❌ Prewarm failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Validation

    private func shouldPrewarm() -> Bool {
        let isEnabled = UserDefaults.standard.bool(forKey: prewarmEnabledKey)
        guard isEnabled else {
            logger.notice("Prewarm disabled by user")
            return false
        }

        // Prewarm every local runtime. Qwen's sherpa-onnx recognizer otherwise
        // performs its first ONNX initialization after recording has started.
        guard
            let model = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model
        else {
            return false
        }

        guard ModelPrewarmPolicy.isLocalProvider(model.provider) else {
            logger.notice("Skipping prewarm - cloud models don't need it")
            return false
        }

        guard
            ModelPrewarmPolicy.shouldRun(
                isEnabled: isEnabled,
                isRecordingActive: AudioDeviceManager.shared.isRecordingActive,
                isUnderRuntimePressure: isSuspendedForRuntimePressure,
                provider: model.provider
            )
        else {
            logger.notice("Skipping prewarm because recording is active")
            return false
        }
        return true
    }

    deinit {
        MainActor.assumeIsolated {
            prewarmTasks.cancelAll()
        }
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        logger.notice("ModelPrewarmService deinitialized")
    }
}
