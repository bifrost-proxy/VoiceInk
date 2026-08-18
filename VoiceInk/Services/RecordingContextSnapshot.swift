import AppKit
import ApplicationServices
import Foundation

enum ContextSource: String, CaseIterable, Hashable, Sendable {
    case selectedText
    case clipboard
    case screenOCR
    case application
    case windowTitle
    case configuredScenario
}

struct ActiveSurfaceContext: Equatable, Sendable {
    let applicationName: String
    /// Used only to identify the local application. Serializers must not send it.
    let bundleIdentifier: String?
    let windowTitle: String?
}

struct RecordingContextSnapshot: Equatable, Sendable {
    var capturedAt = Date()
    var activeSurface: ActiveSurfaceContext?
    var selectedText: String?
    var clipboardText: String?
    var screenOCRText: String?
}

struct ContextFeature: Equatable, Sendable {
    let value: String
    var sources: Set<ContextSource>
    let priority: Int
}

struct RecordingContextTarget: Equatable, Sendable {
    let processID: pid_t
    let activeSurface: ActiveSurfaceContext
    let windowFrame: CGRect?

    @MainActor
    static func capture(excluding excludedProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Self? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != excludedProcessID
        else {
            return nil
        }

        let processID = application.processIdentifier
        var windowTitle: String?
        var windowFrame: CGRect?
        if AXIsProcessTrusted() {
            let applicationElement = AXUIElementCreateApplication(processID)
            if let window = copyAXElementAttribute(kAXFocusedWindowAttribute, from: applicationElement) {
                windowTitle = normalized(copyStringAttribute(kAXTitleAttribute, from: window))
                if let position = copyCGPointAttribute(kAXPositionAttribute, from: window),
                    let size = copyCGSizeAttribute(kAXSizeAttribute, from: window)
                {
                    windowFrame = CGRect(origin: position, size: size)
                }
            }
        }

        let applicationName = normalized(application.localizedName)
            ?? normalized(application.bundleURL?.deletingPathExtension().lastPathComponent)
            ?? "Unknown Application"
        return RecordingContextTarget(
            processID: processID,
            activeSurface: ActiveSurfaceContext(
                applicationName: applicationName,
                bundleIdentifier: application.bundleIdentifier,
                windowTitle: windowTitle
            ),
            windowFrame: windowFrame
        )
    }

    private static func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RecordingContextCapturePlan: Equatable, Sendable {
    let sources: Set<ContextSource>

    static let none = RecordingContextCapturePlan(sources: [])

    var needsSelectedText: Bool { sources.contains(.selectedText) }
    var needsClipboard: Bool { sources.contains(.clipboard) }
    var needsScreenOCR: Bool { sources.contains(.screenOCR) }
    var needsActiveSurface: Bool {
        sources.contains(.application) || sources.contains(.windowTitle)
            || needsSelectedText || needsScreenOCR
    }

    func union(_ other: RecordingContextCapturePlan) -> RecordingContextCapturePlan {
        RecordingContextCapturePlan(sources: sources.union(other.sources))
    }
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot: RecordingContextSnapshot

    init(target: RecordingContextTarget? = nil) {
        snapshot = RecordingContextSnapshot(activeSurface: target?.activeSurface)
    }

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenOCRText(_ text: String?) {
        snapshot.screenOCRText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

@MainActor
struct RecordingContextCaptureTasks {
    let clipboard: Task<Void, Never>?
    let selectedText: Task<Void, Never>?
    let screenOCR: Task<Void, Never>?

    var all: [Task<Void, Never>] {
        [clipboard, selectedText, screenOCR].compactMap { $0 }
    }

    func cancelAll() {
        all.forEach { $0.cancel() }
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(
        plan: RecordingContextCapturePlan,
        target: RecordingContextTarget?,
        into store: RecordingContextSnapshotStore
    ) -> RecordingContextCaptureTasks {
        RecordingContextCaptureTasks(
            clipboard: plan.needsClipboard
                ? Task { @MainActor in
                    store.updateClipboardText(NSPasteboard.general.string(forType: .string))
                }
                : nil,
            selectedText: plan.needsSelectedText && target != nil
                ? Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    let text = await SelectedTextService.fetchSelectedText(
                        targetProcessID: target?.processID
                    )
                    guard !Task.isCancelled else { return }
                    store.updateSelectedText(text)
                }
                : nil,
            screenOCR: plan.needsScreenOCR && target != nil && CGPreflightScreenCaptureAccess()
                ? Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    let text = await ScreenCaptureService().captureAndExtractText(target: target)
                    guard !Task.isCancelled else { return }
                    store.updateScreenOCRText(text)
                }
                : nil
        )
    }
}
