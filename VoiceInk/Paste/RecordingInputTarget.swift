import AppKit
import ApplicationServices
import Foundation
import os

/// The editable accessibility element that owned focus when a recording began.
///
/// Accessibility references are intentionally kept in memory for one recording only. They are
/// never persisted with the transcription or included in recognition context.
@MainActor
struct RecordingInputTarget {
    let processID: pid_t
    let bundleIdentifier: String?
    let window: AXUIElement?
    let element: AXUIElement
    let selectedTextRange: CFRange?
}

enum RecordingInputTargetRestoration: Equatable {
    case restored
    case unavailable
}

@MainActor
enum RecordingInputTargetService {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "RecordingInputTarget"
    )
    private static let activationTimeout: Duration = .milliseconds(600)
    private static let focusTimeout: Duration = .milliseconds(400)
    private static let pollInterval: Duration = .milliseconds(25)

    static func capture(
        excluding excludedProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> RecordingInputTarget? {
        guard AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != excludedProcessID
        else {
            return nil
        }

        let processID = application.processIdentifier
        let applicationElement = AXUIElementCreateApplication(processID)
        guard let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute,
            from: applicationElement
        ) else {
            logger.debug("No focused accessibility element was available when recording began")
            return nil
        }

        return RecordingInputTarget(
            processID: processID,
            bundleIdentifier: application.bundleIdentifier,
            window: copyElementAttribute(kAXFocusedWindowAttribute, from: applicationElement),
            element: focusedElement,
            selectedTextRange: copyRangeAttribute(kAXSelectedTextRangeAttribute, from: focusedElement)
        )
    }

    static func restore(_ target: RecordingInputTarget) async -> RecordingInputTargetRestoration {
        guard AXIsProcessTrusted(),
            let application = NSRunningApplication(processIdentifier: target.processID),
            !application.isTerminated,
            target.bundleIdentifier == nil || application.bundleIdentifier == target.bundleIdentifier
        else {
            logger.notice("The original recording application is no longer available")
            return .unavailable
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processID {
            guard application.activate() else {
                logger.notice("Failed to activate the original recording application")
                return .unavailable
            }
            guard await waitUntil(timeout: activationTimeout, condition: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
            }) else {
                logger.notice("Timed out while activating the original recording application")
                return .unavailable
            }
        }

        let applicationElement = AXUIElementCreateApplication(target.processID)
        if let window = target.window {
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        if !isFocused(target.element, in: applicationElement) {
            _ = AXUIElementSetAttributeValue(
                target.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                target.element
            )
        }

        guard await waitUntil(timeout: focusTimeout, condition: {
            isFocused(target.element, in: applicationElement)
        }) else {
            logger.notice("The original recording input could not regain accessibility focus")
            return .unavailable
        }

        guard restoreSelectionIfSupported(target.selectedTextRange, on: target.element) else {
            logger.notice("The original recording selection could not be restored safely")
            return .unavailable
        }
        return .restored
    }

    private static func restoreSelectionIfSupported(_ range: CFRange?, on element: AXUIElement) -> Bool {
        guard var range else { return true }
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else {
            // Some custom editors expose focus but intentionally do not expose a settable range.
            // Restoring the exact control is still safer than pasting into the current application.
            return true
        }

        guard let value = AXValueCreate(.cfRange, &range) else { return false }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        guard result == .success else { return false }
        guard let restoredRange = copyRangeAttribute(kAXSelectedTextRangeAttribute, from: element) else {
            return false
        }
        return restoredRange.location == range.location && restoredRange.length == range.length
    }

    private static func isFocused(_ element: AXUIElement, in application: AXUIElement) -> Bool {
        guard let focusedElement = copyElementAttribute(kAXFocusedUIElementAttribute, from: application) else {
            return false
        }
        return CFEqual(focusedElement, element)
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return condition()
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

    private static func copyRangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cfRange
        else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}
