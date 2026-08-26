import AppKit
import ApplicationServices
import Foundation
import os

/// The application window and focused control that were active when a recording began.
///
/// These references are intentionally kept in memory for one recording only. They are never
/// persisted with the transcription or included in recognition context.
@MainActor
struct RecordingInputTarget {
    let processID: pid_t
    let bundleIdentifier: String?
    let window: AXUIElement?
    let focusedElement: AXUIElement?
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
        let accessibilityApplication = AXUIElementCreateApplication(processID)
        let window: AXUIElement?
        let focusedElement: AXUIElement?
        if AXIsProcessTrusted() {
            window = copyElementAttribute(
                kAXFocusedWindowAttribute,
                from: accessibilityApplication
            )
            focusedElement = copyElementAttribute(
                kAXFocusedUIElementAttribute,
                from: accessibilityApplication
            )
        } else {
            window = nil
            focusedElement = nil
        }

        return RecordingInputTarget(
            processID: processID,
            bundleIdentifier: application.bundleIdentifier,
            window: window,
            focusedElement: focusedElement
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

        let accessibilityApplication = AXUIElementCreateApplication(target.processID)
        if let targetWindow = target.window {
            guard AXIsProcessTrusted(),
                let focusedWindow = copyElementAttribute(
                    kAXFocusedWindowAttribute,
                    from: accessibilityApplication
                ),
                CFEqual(focusedWindow, targetWindow)
            else {
                logger.notice("The original recording window is no longer active")
                return .unavailable
            }
        }

        if let targetElement = target.focusedElement {
            guard AXIsProcessTrusted(),
                let focusedElement = copyElementAttribute(
                    kAXFocusedUIElementAttribute,
                    from: accessibilityApplication
                ),
                CFEqual(focusedElement, targetElement)
            else {
                logger.notice("The original recording control is no longer focused")
                return .unavailable
            }
        }

        // Some applications do not expose accessibility window or control references. The
        // application identity still prevents delivery to a different process, and Cmd+V follows
        // the application's current focus without VoiceInk changing it.
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
