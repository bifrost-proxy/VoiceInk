import AppKit
import ApplicationServices
import Foundation
import SwiftData
import os

struct PostPasteTextChange: Equatable {
    let oldRange: NSRange
    let removedText: String
    let insertedText: String

    var lengthDelta: Int {
        insertedText.utf16.count - oldRange.length
    }

    static func between(_ oldText: String, _ newText: String) -> PostPasteTextChange? {
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)

        var prefixCount = 0
        while prefixCount < oldUnits.count,
            prefixCount < newUnits.count,
            oldUnits[prefixCount] == newUnits[prefixCount]
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldUnits.count - prefixCount,
            suffixCount < newUnits.count - prefixCount,
            oldUnits[oldUnits.count - suffixCount - 1] == newUnits[newUnits.count - suffixCount - 1]
        {
            suffixCount += 1
        }

        let oldEnd = oldUnits.count - suffixCount
        let newEnd = newUnits.count - suffixCount
        guard prefixCount != oldEnd || prefixCount != newEnd else { return nil }

        return PostPasteTextChange(
            oldRange: NSRange(location: prefixCount, length: oldEnd - prefixCount),
            removedText: String(decoding: oldUnits[prefixCount..<oldEnd], as: UTF16.self),
            insertedText: String(decoding: newUnits[prefixCount..<newEnd], as: UTF16.self)
        )
    }

    func applying(to trackedRange: NSRange, newTextUTF16Count: Int) -> (range: NSRange, affected: Bool) {
        let trackedStart = trackedRange.location
        let trackedEnd = trackedRange.location + trackedRange.length
        let editStart = oldRange.location
        let editEnd = oldRange.location + oldRange.length
        let insertedLength = insertedText.utf16.count

        if oldRange.length == 0 {
            if editStart < trackedStart {
                return (
                    clamped(
                        NSRange(location: trackedStart + insertedLength, length: trackedRange.length),
                        maximumLength: newTextUTF16Count),
                    false
                )
            }

            if editStart <= trackedEnd {
                return (
                    clamped(
                        NSRange(location: trackedStart, length: trackedRange.length + insertedLength),
                        maximumLength: newTextUTF16Count),
                    true
                )
            }

            return (clamped(trackedRange, maximumLength: newTextUTF16Count), false)
        }

        if editEnd <= trackedStart {
            return (
                clamped(
                    NSRange(location: max(0, trackedStart + lengthDelta), length: trackedRange.length),
                    maximumLength: newTextUTF16Count),
                false
            )
        }

        if editStart >= trackedEnd {
            return (clamped(trackedRange, maximumLength: newTextUTF16Count), false)
        }

        if editStart <= trackedStart, editEnd >= trackedEnd {
            return (
                clamped(
                    NSRange(location: editStart, length: insertedLength),
                    maximumLength: newTextUTF16Count),
                true
            )
        }

        let newStart = min(trackedStart, editStart)
        let newEnd = max(newStart, trackedEnd + lengthDelta)
        return (
            clamped(
                NSRange(location: newStart, length: newEnd - newStart),
                maximumLength: newTextUTF16Count),
            true
        )
    }

    private func clamped(_ range: NSRange, maximumLength: Int) -> NSRange {
        let location = min(max(0, range.location), maximumLength)
        let length = min(max(0, range.length), maximumLength - location)
        return NSRange(location: location, length: length)
    }
}

@MainActor
final class PostPasteEditTracker {
    static let userDefaultsKey = "TrackPostPasteEdits"

    private final class Session {
        let transcription: Transcription
        let element: AXUIElement
        let deliveredText: String
        let selectedRangeBeforePaste: NSRange
        let valueBeforePaste: String
        let startedAt = Date()

        var trackedRange = NSRange(location: 0, length: 0)
        var lastFullText = ""
        var currentTrackedText = ""
        var lastPersistedText = ""
        var pollTask: Task<Void, Never>?
        var settleTask: Task<Void, Never>?

        init(
            transcription: Transcription,
            element: AXUIElement,
            deliveredText: String,
            selectedRangeBeforePaste: NSRange,
            valueBeforePaste: String
        ) {
            self.transcription = transcription
            self.element = element
            self.deliveredText = deliveredText
            self.selectedRangeBeforePaste = selectedRangeBeforePaste
            self.valueBeforePaste = valueBeforePaste
        }
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PostPasteEditTracker")
    private let modelContext: ModelContext
    private var activeSession: Session?

    private static let pasteVerificationDelayNanoseconds: UInt64 = 250_000_000
    private static let pollingIntervalNanoseconds: UInt64 = 500_000_000
    private static let editSettleDelayNanoseconds: UInt64 = 1_200_000_000
    private static let observationDuration: TimeInterval = 120
    private static let maximumTargetTextLength = 200_000

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func prepare(transcription: Transcription, deliveredText: String) -> AnyObject? {
        finishActiveSession(fallbackStatus: .superseded)

        transcription.deliveredText = deliveredText
        transcription.pasteStartedAt = Date()
        transcription.pasteTrackingFinishedAt = nil
        transcription.finalEditedText = nil
        transcription.postPasteEditRecords = []

        guard UserDefaults.standard.bool(forKey: Self.userDefaultsKey) else {
            transcription.pasteTrackingStatusValue = .disabled
            saveChanges()
            return nil
        }

        guard AXIsProcessTrusted() else {
            transcription.pasteTrackingStatusValue = .unavailable
            saveChanges()
            return nil
        }

        guard let element = Self.focusedElement() else {
            transcription.pasteTrackingStatusValue = .unsupportedTarget
            saveChanges()
            return nil
        }

        populateTargetMetadata(for: transcription, element: element)

        let role = Self.stringAttribute(kAXRoleAttribute, from: element)
        let subrole = Self.stringAttribute(kAXSubroleAttribute, from: element)
        if Self.isSecureField(role: role, subrole: subrole) {
            transcription.pasteTrackingStatusValue = .secureField
            saveChanges()
            return nil
        }

        guard let value = Self.stringAttribute(kAXValueAttribute, from: element),
            value.utf16.count <= Self.maximumTargetTextLength,
            let selectedRange = Self.rangeAttribute(kAXSelectedTextRangeAttribute, from: element),
            selectedRange.location >= 0,
            selectedRange.length >= 0,
            selectedRange.location + selectedRange.length <= value.utf16.count
        else {
            transcription.pasteTrackingStatusValue = .unsupportedTarget
            saveChanges()
            return nil
        }

        let session = Session(
            transcription: transcription,
            element: element,
            deliveredText: deliveredText,
            selectedRangeBeforePaste: selectedRange,
            valueBeforePaste: value
        )
        activeSession = session
        transcription.pasteTrackingStatusValue = .observing
        saveChanges()
        return session
    }

    func completePaste(preparation: AnyObject?, result: CursorPaster.PasteResult, autoSent: Bool) async {
        guard let session = preparation as? Session,
            activeSession === session
        else {
            return
        }

        guard result.didPostPasteCommand else {
            finish(session, fallbackStatus: .pasteFailed)
            return
        }

        if autoSent {
            finish(session, fallbackStatus: .autoSent)
            return
        }

        try? await Task.sleep(nanoseconds: Self.pasteVerificationDelayNanoseconds)
        guard activeSession === session,
            let currentValue = Self.stringAttribute(kAXValueAttribute, from: session.element),
            let insertedRange = locateDeliveredText(in: currentValue, for: session)
        else {
            finish(session, fallbackStatus: .pasteNotVerified)
            return
        }

        session.trackedRange = insertedRange
        session.lastFullText = currentValue
        session.currentTrackedText = Self.substring(currentValue, range: insertedRange) ?? session.deliveredText
        session.lastPersistedText = session.currentTrackedText
        session.transcription.finalEditedText = session.currentTrackedText
        session.transcription.pasteTrackingStatusValue = .observing
        saveChanges()
        startPolling(session)
    }

    private func startPolling(_ session: Session) {
        session.pollTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }

            while !Task.isCancelled,
                self.activeSession === session,
                Date().timeIntervalSince(session.startedAt) < Self.observationDuration
            {
                try? await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds)
                guard !Task.isCancelled, self.activeSession === session else { return }

                guard let newValue = Self.stringAttribute(kAXValueAttribute, from: session.element),
                    newValue.utf16.count <= Self.maximumTargetTextLength
                else {
                    self.finish(session, fallbackStatus: .unsupportedTarget)
                    return
                }

                self.captureChanges(in: newValue, session: session)

                if let focusedElement = Self.focusedElement(), !CFEqual(focusedElement, session.element) {
                    self.finish(session, fallbackStatus: .unchanged)
                    return
                }
            }

            if self.activeSession === session {
                self.finish(session, fallbackStatus: .timedOut)
            }
        }
    }

    private func captureChanges(in newValue: String, session: Session) {
        guard newValue != session.lastFullText,
            let change = PostPasteTextChange.between(session.lastFullText, newValue)
        else {
            return
        }

        let adjusted = change.applying(
            to: session.trackedRange,
            newTextUTF16Count: newValue.utf16.count
        )
        session.trackedRange = adjusted.range
        session.lastFullText = newValue

        guard adjusted.affected,
            let trackedText = Self.substring(newValue, range: adjusted.range),
            trackedText != session.currentTrackedText
        else {
            return
        }

        session.currentTrackedText = trackedText
        session.transcription.finalEditedText = trackedText
        scheduleSettledEdit(for: session)
    }

    private func scheduleSettledEdit(for session: Session) {
        session.settleTask?.cancel()
        session.settleTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: Self.editSettleDelayNanoseconds)
            guard !Task.isCancelled, let self, let session, self.activeSession === session else { return }
            self.persistSettledEdit(for: session)
        }
    }

    private func persistSettledEdit(for session: Session) {
        guard session.currentTrackedText != session.lastPersistedText,
            let change = PostPasteTextChange.between(session.lastPersistedText, session.currentTrackedText)
        else {
            return
        }

        session.transcription.appendPostPasteEditRecord(
            TranscriptionEditRecord(
                removedText: change.removedText,
                insertedText: change.insertedText,
                resultingText: session.currentTrackedText
            )
        )
        session.lastPersistedText = session.currentTrackedText
        session.transcription.finalEditedText = session.currentTrackedText
        saveChanges()
    }

    private func finishActiveSession(fallbackStatus: PasteTrackingStatus) {
        guard let activeSession else { return }
        finish(activeSession, fallbackStatus: fallbackStatus)
    }

    private func finish(_ session: Session, fallbackStatus: PasteTrackingStatus) {
        session.pollTask?.cancel()
        session.settleTask?.cancel()
        persistSettledEdit(for: session)

        session.transcription.pasteTrackingStatusValue = session.transcription.postPasteEditRecords.isEmpty
            ? fallbackStatus : .edited
        session.transcription.pasteTrackingFinishedAt = Date()
        saveChanges()

        if activeSession === session {
            activeSession = nil
        }
    }

    private func locateDeliveredText(in value: String, for session: Session) -> NSRange? {
        let valueNSString = value as NSString
        let expectedRange = NSRange(
            location: session.selectedRangeBeforePaste.location,
            length: session.deliveredText.utf16.count
        )
        if expectedRange.location + expectedRange.length <= valueNSString.length,
            valueNSString.substring(with: expectedRange) == session.deliveredText
        {
            return expectedRange
        }

        let searchStart = max(0, session.selectedRangeBeforePaste.location - 64)
        let searchEnd = min(
            valueNSString.length,
            session.selectedRangeBeforePaste.location + session.deliveredText.utf16.count + 64
        )
        guard searchEnd >= searchStart else { return nil }
        let nearbyRange = NSRange(location: searchStart, length: searchEnd - searchStart)
        let foundRange = valueNSString.range(of: session.deliveredText, options: [], range: nearbyRange)
        return foundRange.location == NSNotFound ? nil : foundRange
    }

    private func populateTargetMetadata(for transcription: Transcription, element: AXUIElement) {
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        let application = NSRunningApplication(processIdentifier: processID)
        transcription.pasteTargetApplicationName = application?.localizedName
        transcription.pasteTargetBundleIdentifier = application?.bundleIdentifier
        transcription.pasteTargetElementRole = Self.stringAttribute(kAXRoleAttribute, from: element)
        transcription.pasteTargetElementIdentifier = Self.stringAttribute(kAXIdentifierAttribute, from: element)

        if let window = Self.elementAttribute(kAXWindowAttribute, from: element) {
            transcription.pasteTargetWindowTitle = Self.stringAttribute(kAXTitleAttribute, from: window)
        }
    }

    private func saveChanges() {
        guard let transcription = activeSession?.transcription else { return }
        transcription.syncModifiedAt = Date()
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        } catch {
            logger.error("Failed to save post-paste edit tracking: \(error, privacy: .public)")
        }
    }

    private static func focusedElement() -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, from: AXUIElementCreateSystemWide())
    }

    private static func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func rangeAttribute(_ attribute: String, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cfRange
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func substring(_ text: String, range: NSRange) -> String? {
        let text = text as NSString
        guard range.location >= 0,
            range.length >= 0,
            range.location + range.length <= text.length
        else {
            return nil
        }
        return text.substring(with: range)
    }

    private static func isSecureField(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }
    }
}
