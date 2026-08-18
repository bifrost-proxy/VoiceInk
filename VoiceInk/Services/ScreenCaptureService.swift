import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import Vision

@MainActor
class ScreenCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var lastCapturedText: String?

    private nonisolated static let captureTimeout: TimeInterval = 3.0
    private nonisolated static let maximumCaptureDimension: CGFloat = 2800
    private nonisolated static let focusedWindowFrameTolerance: CGFloat = 96

    static func requestScreenCapturePermissionRegistration() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // CGRequestScreenCaptureAccess blocks the calling thread while macOS
        // owns the permission dialog. Keep it off MainActor so recorder UI,
        // shortcut handling, and other app work remain responsive.
        return await performPermissionRequest {
            CGRequestScreenCaptureAccess()
        }
    }

    static func performPermissionRequest(
        _ request: @escaping @Sendable () -> Bool
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            request()
        }.value
    }

    func captureAndExtractText(target: RecordingContextTarget? = nil) async -> String? {
        guard !isCapturing else { return nil }

        isCapturing = true
        defer {
            isCapturing = false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let lockedTarget = target ?? RecordingContextTarget.capture(excluding: currentPID)

        guard
            let contextText = await Self.withTimeout(
                seconds: Self.captureTimeout,
                operation: {
                    await Self.captureAndExtractWindowText(
                        target: lockedTarget,
                        currentPID: currentPID
                    )
                })
        else {
            return nil
        }

        lastCapturedText = contextText
        return contextText
    }

    private nonisolated static func captureAndExtractWindowText(
        target: RecordingContextTarget?,
        currentPID: pid_t
    ) async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard
                let window = findActiveWindow(
                    in: content.windows,
                    target: target,
                    currentPID: currentPID
                )
            else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)

            let configuration = SCStreamConfiguration()
            let captureScale = captureScale(for: window.frame.size)
            configuration.width = max(1, Int(window.frame.width * captureScale))
            configuration.height = max(1, Int(window.frame.height * captureScale))

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)

            let extractedText = extractText(from: cgImage)
            return normalized(extractedText)

        } catch {
            return nil
        }
    }

    private nonisolated static func findActiveWindow(
        in windows: [SCWindow],
        target: RecordingContextTarget?,
        currentPID: pid_t
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard let processID = window.owningApplication?.processID else {
                return false
            }

            return processID != currentPID && window.windowLayer == 0 && window.isOnScreen && window.frame.width > 0
                && window.frame.height > 0
        }

        guard let target else {
            return candidates.first
        }

        let appWindows = candidates.filter {
            $0.owningApplication?.processID == target.processID
        }

        // A locked target must never fall back to another application's window.
        guard !appWindows.isEmpty else { return nil }

        if let focusedFrame = target.windowFrame,
            let closestWindow = closestFrameMatch(to: focusedFrame, in: appWindows),
            frameDistance(closestWindow.frame, focusedFrame) <= focusedWindowFrameTolerance
        {
            return closestWindow
        }

        if let focusedTitle = target.activeSurface.windowTitle,
            let titledWindow = appWindows.first(where: { normalized($0.title) == focusedTitle })
        {
            return titledWindow
        }

        return appWindows.first
    }

    private nonisolated static func closestFrameMatch(to frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        windows.min {
            frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
        }
    }

    private nonisolated static func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.origin.x - second.origin.x) + abs(first.origin.y - second.origin.y)
            + abs(first.size.width - second.size.width) + abs(first.size.height - second.size.height)
    }

    private nonisolated static func captureScale(for size: CGSize) -> CGFloat {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else {
            return 1
        }

        return min(2, maximumCaptureDimension / longestSide)
    }

    private nonisolated static func extractText(from cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try requestHandler.perform([request])
            guard let observations = request.results else {
                return nil
            }
            let text =
                observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ text: String?) -> String? {
        Self.normalized(text)
    }
}
