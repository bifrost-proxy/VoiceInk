import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
struct RecordingContextCaptureTasks {
    let clipboard: Task<Void, Never>
    let selectedText: Task<Void, Never>
    let screenText: Task<Void, Never>

    var all: [Task<Void, Never>] {
        [clipboard, selectedText, screenText]
    }

    func cancelAll() {
        all.forEach { $0.cancel() }
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> RecordingContextCaptureTasks {
        RecordingContextCaptureTasks(
            clipboard: Task { @MainActor in
                store.updateClipboardText(NSPasteboard.general.string(forType: .string))
            },
            selectedText: Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            },
            screenText: Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            }
        )
    }
}
