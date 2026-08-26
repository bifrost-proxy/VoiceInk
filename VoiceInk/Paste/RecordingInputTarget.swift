import AppKit
import ApplicationServices
import Foundation
import os

/// The application window that was active when a recording began.
///
/// The window reference is intentionally kept in memory for one recording only. It is never
/// persisted with the transcription or included in recognition context.
@MainActor
struct RecordingInputTarget {
    let processID: pid_t
    let bundleIdentifier: String?
    let window: AXUIElement?
}

enum RecordingInputTargetAvailability: Equatable {
    case active
    case unavailable
}

@MainActor
enum RecordingInputTargetService {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "RecordingInputTarget"
    )

    static func capture(
        excluding excludedProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> RecordingInputTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != excludedProcessID
        else {
            return nil
        }

        let processID = application.processIdentifier
        let window = if AXIsProcessTrusted() {
            copyElementAttribute(
                kAXFocusedWindowAttribute,
                from: AXUIElementCreateApplication(processID)
            )
        } else {
            nil
        }

        return RecordingInputTarget(
            processID: processID,
            bundleIdentifier: application.bundleIdentifier,
            window: window
        )
    }

    /// Checks whether paste can still be delivered without changing application, window, focus,
    /// or selection state. This method is intentionally read-only.
    static func availability(of target: RecordingInputTarget) -> RecordingInputTargetAvailability {
        guard let application = NSRunningApplication(processIdentifier: target.processID),
            !application.isTerminated,
            target.bundleIdentifier == nil || application.bundleIdentifier == target.bundleIdentifier
        else {
            logger.notice("The original recording application is no longer available")
            return .unavailable
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
            logger.notice("The original recording application is no longer active")
            return .unavailable
        }

        guard let targetWindow = target.window else {
            // Some applications do not expose a focused accessibility window. The application
            // identity still prevents delivery to a different process, and Cmd+V follows the
            // application's current focus without VoiceInk changing it.
            return .active
        }

        guard AXIsProcessTrusted(),
            let focusedWindow = copyElementAttribute(
                kAXFocusedWindowAttribute,
                from: AXUIElementCreateApplication(target.processID)
            ),
            CFEqual(focusedWindow, targetWindow)
        else {
            logger.notice("The original recording window is no longer active")
            return .unavailable
        }
        return .active
    }

    private static func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }
}
