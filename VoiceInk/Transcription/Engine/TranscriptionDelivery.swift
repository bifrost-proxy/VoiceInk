import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    typealias PasteAtCursor = @MainActor (
        String,
        @escaping @MainActor () -> Bool
    ) async -> CursorPaster.PasteResult
    typealias RestoreInputTarget = @MainActor (RecordingInputTarget) async -> RecordingInputTargetRestoration
    typealias CaptureEditableTextState = @MainActor (RecordingInputTarget) -> RecordingEditableTextState?
    typealias CopyToClipboard = @MainActor (String) -> Bool
    typealias NotifyUnavailableTarget = @MainActor () -> Void
    typealias NotifyInterruptedDelivery = @MainActor () -> Void
    typealias AppendTrailingSpace = @MainActor () -> Bool
    typealias AutoSendScheduler = @MainActor (AutoSendKey, RecordingInputTarget?) -> Void

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")
    private let pasteAtCursor: PasteAtCursor
    private let restoreInputTarget: RestoreInputTarget
    private let captureEditableTextState: CaptureEditableTextState
    private let copyToClipboard: CopyToClipboard
    private let notifyUnavailableTarget: NotifyUnavailableTarget
    private let notifyInterruptedDelivery: NotifyInterruptedDelivery
    private let appendTrailingSpace: AppendTrailingSpace
    private let autoSendScheduler: AutoSendScheduler?

    init(
        pasteAtCursor: @escaping PasteAtCursor = { text, shouldCancel in
            await CursorPaster.pasteAtCursorAndWaitUntilPosted(text, shouldCancel: shouldCancel)
        },
        restoreInputTarget: @escaping RestoreInputTarget = { target in
            await RecordingInputTargetService.restore(target)
        },
        captureEditableTextState: @escaping CaptureEditableTextState = { target in
            RecordingInputTargetService.editableTextState(for: target)
        },
        copyToClipboard: @escaping CopyToClipboard = { text in
            ClipboardManager.copyToClipboard(text)
        },
        notifyUnavailableTarget: @escaping NotifyUnavailableTarget = {
            NotificationManager.shared.showNotification(
                title: String(localized: "Original input is no longer available. Transcription copied to clipboard."),
                type: .warning,
                duration: 6.0
            )
        },
        notifyInterruptedDelivery: @escaping NotifyInterruptedDelivery = {
            NotificationManager.shared.showNotification(
                title: String(localized: "Input changed before transcription could be inserted. Transcription remains in VoiceInk history."),
                type: .warning,
                duration: 6.0
            )
        },
        appendTrailingSpace: @escaping AppendTrailingSpace = {
            UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        },
        autoSendScheduler: AutoSendScheduler? = nil
    ) {
        self.pasteAtCursor = pasteAtCursor
        self.restoreInputTarget = restoreInputTarget
        self.captureEditableTextState = captureEditableTextState
        self.copyToClipboard = copyToClipboard
        self.notifyUnavailableTarget = notifyUnavailableTarget
        self.notifyInterruptedDelivery = notifyInterruptedDelivery
        self.appendTrailingSpace = appendTrailingSpace
        self.autoSendScheduler = autoSendScheduler
    }

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let inputTarget: RecordingInputTarget?
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    struct ProvisionalPasteResult {
        let wasDelivered: Bool
        let didPostPasteCommand: Bool
        let replacementSession: ProvisionalTextReplacementSession?

        /// Continue enhancement only when its result can still be delivered. A failed provisional
        /// paste falls back to the normal final delivery path, while a successful raw delivery
        /// without a replacement session must keep the raw text and avoid wasted enhancement work.
        var shouldContinueEnhancement: Bool {
            !wasDelivered || replacementSession != nil
        }
    }

    /// Immediately pastes an unenhanced transcript after the user skips an in-flight enhancement.
    /// This intentionally does not auto-send, because the user asked to regain the text quickly,
    /// not to submit it before reviewing the raw transcript.
    func pasteOriginalImmediately(
        _ text: String,
        inputTarget: RecordingInputTarget?,
        dismiss: @escaping () async -> Void
    ) async {
        await paste(
            text,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .none,
                customCommand: nil
            ),
            inputTarget: inputTarget,
            actions: Actions(
                setState: { _ in },
                dismiss: dismiss,
                sendFollowUp: { _, _ in },
                showResponse: { _, _ in },
                failResponse: { _ in }
            )
        )
    }

    /// Inserts the raw transcript immediately while enhancement continues. When the target exposes
    /// a verifiable plain-text accessibility state, the returned session can later replace only the
    /// inserted transcript. Unsupported targets still keep the safely pasted raw text.
    func deliverOriginalProvisionally(
        _ text: String,
        inputTarget: RecordingInputTarget,
        dismiss: @escaping () async -> Void,
        shouldCancel: @escaping @MainActor () -> Bool,
        onUserInteraction: @escaping @MainActor () -> Void
    ) async -> ProvisionalPasteResult {
        guard !shouldCancel() else {
            return ProvisionalPasteResult(
                wasDelivered: false,
                didPostPasteCommand: false,
                replacementSession: nil
            )
        }
        let appendSpace = appendTrailingSpace()
        let trailingText = appendSpace ? " " : ""
        let pastedText = text + trailingText

        SoundManager.shared.playStopSound()
        await dismiss()

        guard !shouldCancel() else {
            return ProvisionalPasteResult(
                wasDelivered: false,
                didPostPasteCommand: false,
                replacementSession: nil
            )
        }

        switch await restoreInputTarget(inputTarget) {
        case .restored:
            break
        case .canceled:
            return ProvisionalPasteResult(
                wasDelivered: false,
                didPostPasteCommand: false,
                replacementSession: nil
            )
        case .unavailable:
            if copyToClipboard(pastedText) {
                notifyUnavailableTarget()
                return ProvisionalPasteResult(
                    wasDelivered: true,
                    didPostPasteCommand: false,
                    replacementSession: nil
                )
            }
            return ProvisionalPasteResult(
                wasDelivered: false,
                didPostPasteCommand: false,
                replacementSession: nil
            )
        }

        guard !shouldCancel() else {
            return ProvisionalPasteResult(
                wasDelivered: false,
                didPostPasteCommand: false,
                replacementSession: nil
            )
        }

        let replacementSession = captureEditableTextState(inputTarget).flatMap { state in
            ProvisionalTextReplacementSession(
                target: inputTarget,
                preInsertionState: state,
                insertedText: pastedText,
                replacementText: text,
                onUserInteraction: onUserInteraction
            )
        }
        replacementSession?.beginIgnoringPasteShortcut()
        let pasteResult = await pasteAtCursor(pastedText) {
            shouldCancel() || Task.isCancelled || replacementSession?.wasCanceledByUser == true
        }
        replacementSession?.endIgnoringPasteShortcut()
        guard pasteResult.didPostCommand else {
            let wasCanceledByUser = replacementSession?.wasCanceledByUser == true
            replacementSession?.stopMonitoring()
            if wasCanceledByUser && !shouldCancel() {
                reportOriginalNotInsertedAfterInteraction()
                return ProvisionalPasteResult(
                    wasDelivered: true,
                    didPostPasteCommand: false,
                    replacementSession: nil
                )
            }
            return ProvisionalPasteResult(
                wasDelivered: false,
                didPostPasteCommand: false,
                replacementSession: nil
            )
        }

        replacementSession?.setClipboardOwnership(pasteResult.clipboardOwnership)
        return ProvisionalPasteResult(
            wasDelivered: true,
            didPostPasteCommand: true,
            replacementSession: replacementSession
        )
    }

    /// A user interaction makes another automatic paste and any clipboard overwrite unsafe. The
    /// raw transcript is still persisted in VoiceInk history, so report that recovery path while
    /// leaving clipboard content created by the user's interaction untouched.
    func reportOriginalNotInsertedAfterInteraction() {
        notifyInterruptedDelivery()
    }

    func completeProvisionalDelivery(
        _ session: ProvisionalTextReplacementSession,
        enhancedText: String,
        output: OutputRuntimeConfiguration,
        inputTarget: RecordingInputTarget,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> ProvisionalTextReplacementSession.ReplacementResult {
        let result = await session.replace(with: enhancedText, shouldCancel: shouldCancel)
        if result == .replaced,
            !shouldCancel(),
            !Task.isCancelled,
            output.outputMode == .paste,
            output.autoSendKey.isEnabled
        {
            scheduleAutoSend(output.autoSendKey, inputTarget: inputTarget)
        }
        return result
    }

    /// Keeps an already-inserted raw transcript when enhancement is skipped or fails. When a
    /// replacement session exists, auto-send is allowed only if the exact raw value and caret are
    /// still unchanged and no user interaction canceled the transaction.
    @discardableResult
    func finishProvisionalDeliveryWithoutEnhancement(
        _ session: ProvisionalTextReplacementSession?,
        output: OutputRuntimeConfiguration,
        inputTarget: RecordingInputTarget,
        didPostPasteCommand: Bool,
        verifyInsertionAfterCancellation: Bool = false,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) async -> ProvisionalTextReplacementSession.ReplacementResult {
        let result = await session?.finishKeepingOriginal(
            verifyInsertionAfterCancellation: verifyInsertionAfterCancellation,
            shouldCancel: shouldCancel
        ) ?? .originalRetained
        if !verifyInsertionAfterCancellation,
            !shouldCancel(),
            !Task.isCancelled,
            didPostPasteCommand,
            result == .originalRetained,
            output.outputMode == .paste,
            output.autoSendKey.isEnabled
        {
            scheduleAutoSend(output.autoSendKey, inputTarget: inputTarget)
        }
        return result
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, output: request.output, inputTarget: request.inputTarget, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: text)
        }
    }

    private func runCustomCommand(command: String, commandText: String) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(
        _ text: String,
        output: OutputRuntimeConfiguration,
        inputTarget: RecordingInputTarget?,
        actions: Actions
    ) async {
        let appendSpace = appendTrailingSpace()
        let pastedText = text + (appendSpace ? " " : "")
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        if let inputTarget {
            switch await restoreInputTarget(inputTarget) {
            case .restored:
                break
            case .unavailable:
                if copyToClipboard(pastedText) {
                    notifyUnavailableTarget()
                }
                return
            case .canceled:
                return
            }
        }

        let pasteResult = await pasteAtCursor(pastedText) { Task.isCancelled }

        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none
        if autoSendKey.isEnabled, pasteResult.didPostCommand {
            scheduleAutoSend(autoSendKey, inputTarget: inputTarget)
        }
    }

    private func scheduleAutoSend(_ key: AutoSendKey, inputTarget: RecordingInputTarget?) {
        if let autoSendScheduler {
            autoSendScheduler(key, inputTarget)
            return
        }
        Task { @MainActor [restoreInputTarget] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let inputTarget,
                await restoreInputTarget(inputTarget) != .restored
            {
                return
            }
            CursorPaster.performAutoSend(key)
        }
    }

}
