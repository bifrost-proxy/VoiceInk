import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery: TranscriptionDelivery
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
        self.delivery = TranscriptionDelivery()
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        captureIntegritySnapshot: AudioCaptureIntegritySnapshot? = nil,
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        shouldBypassEnhancement: () -> Bool = { false },
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive
    ) async {
        let processingStartedAt = Date()
        let model = transcriptionConfiguration.model
        var finalText: String?
        var didInsertSessionMetric = false
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?
        var postProcessingDuration: TimeInterval?
        var deliveryDuration: TimeInterval?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )
            var performance = session?.performanceSnapshot
                ?? TranscriptionPerformanceSnapshot(executionMode: "batch")
            performance.recordCaptureIntegrity(captureIntegritySnapshot)
            performance.totalProcessingDuration = Date().timeIntervalSince(processingStartedAt)
            transcription.performanceSnapshot = performance
            transcription.syncModifiedAt = Date()

            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: transcriptionConfiguration.requestContext
                )
            }
            text = TranscriptionOutputFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            let postProcessingStartedAt = Date()

            if shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw VoiceInkEngineError.noSpeechDetected
            }

            if !assistant.isFollowUp,
                let processedText = triggerWordModeSelection(text)
            {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ?? resolvedEnhancementConfiguration?.mode
                    ?? resolvedOutputConfiguration.mode ?? transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText
            postProcessingDuration = Date().timeIntervalSince(postProcessingStartedAt)

            if !assistant.isFollowUp {
                let shouldRespondInRecorder =
                    resolvedOutputConfiguration.outputMode == .respond
                    && resolvedEnhancementConfiguration?.isEnabled == true
                    && resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement =
                    !shouldRespondInRecorder && isSkipShortEnhancementEnabled
                    && WordCounter.count(in: text) <= shortEnhancementWordThreshold

                let enhancementIsConfigured = resolvedEnhancementConfiguration.map { configuration in
                    enhancementService?.isConfigured(for: configuration) == true
                } == true

                if let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    !enhancementIsConfigured
                {
                    logger.warning(
                        "AI enhancement skipped because the selected mode is not fully configured"
                    )
                    NotificationManager.shared.showNotification(
                        title: String(localized: "AI Enhancement is not enabled or configured"),
                        type: .warning
                    )
                }

                if let enhancementService,
                    let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    enhancementIsConfigured,
                    !shouldSkipEnhancement
                {
                    if shouldCancel() {
                        await finishCanceledTranscription()
                        return
                    }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        let contextSnapshot = await recordingContextSnapshot()
                        if shouldBypassEnhancement() {
                            finalText = cleanedText
                        } else {
                            let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                                textForAI,
                                configuration: resolvedEnhancementConfiguration,
                                contextSnapshot: contextSnapshot
                            )
                            if shouldBypassEnhancement() {
                                finalText = cleanedText
                            } else {
                                transcription.enhancedText = enhancedText
                                transcription.aiEnhancementModelName =
                                    resolvedEnhancementConfiguration.modelName
                                    ?? resolvedEnhancementConfiguration.provider?.defaultModel
                                transcription.promptName = promptName
                                transcription.enhancementDuration = enhancementDuration
                                transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                                transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                                finalText = enhancedText
                            }
                        }
                    } catch {
                        if shouldBypassEnhancement() {
                            finalText = cleanedText
                        } else {
                            let errorDescription = EnhancementFailureFormatter.description(for: error)
                            let failureMessage = EnhancementFailureFormatter.message(description: errorDescription)
                            transcription.enhancedText = failureMessage
                            responseError = errorDescription
                            await MainActor.run {
                                NotificationManager.shared.showNotification(
                                    title: failureMessage,
                                    type: .warning
                                )
                            }
                            if shouldCancel() {
                                await finishCanceledTranscription()
                                return
                            }
                        }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
                nativeAppleError.shouldShowNotification
            {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            if case VoiceInkEngineError.noSpeechDetected = error {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .warning,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            var performance = session?.performanceSnapshot
                ?? TranscriptionPerformanceSnapshot(executionMode: "batch")
            performance.recordCaptureIntegrity(captureIntegritySnapshot)
            performance.transcriptionDuration = transcription.transcriptionDuration
            performance.postProcessingDuration = postProcessingDuration
            performance.enhancementDuration = transcription.enhancementDuration
            performance.deliveryDuration = deliveryDuration
            performance.totalProcessingDuration = Date().timeIntervalSince(processingStartedAt)
            transcription.performanceSnapshot = performance
            transcription.syncModifiedAt = Date()

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        if !shouldBypassEnhancement() {
            let deliveryStartedAt = Date()
            await delivery.deliver(
                TranscriptionDelivery.Request(
                    transcription: transcription,
                    text: finalText,
                    output: outputForDelivery ?? outputConfiguration(),
                    responseConfig: responseConfig,
                    responseError: responseError,
                    isAssistantFollowUp: assistant.isFollowUp
                ),
                actions: TranscriptionDelivery.Actions(
                    setState: onStateChange,
                    dismiss: onDismiss,
                    sendFollowUp: assistant.sendFollowUp,
                    showResponse: assistant.showResponse,
                    failResponse: assistant.failResponse
                )
            )
            deliveryDuration = Date().timeIntervalSince(deliveryStartedAt)
        }

        saveTranscriptionAndPostCompletion()
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}
