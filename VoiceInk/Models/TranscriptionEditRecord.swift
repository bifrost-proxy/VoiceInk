import Foundation

enum PasteTrackingStatus: String, Codable {
    case disabled
    case unavailable
    case secureField
    case unsupportedTarget
    case pasteFailed
    case pasteNotVerified
    case autoSent
    case observing
    case unchanged
    case edited
    case superseded
    case timedOut

    var displayName: String {
        switch self {
        case .disabled: return String(localized: "Tracking disabled")
        case .unavailable: return String(localized: "Accessibility unavailable")
        case .secureField: return String(localized: "Skipped secure field")
        case .unsupportedTarget: return String(localized: "Unsupported text field")
        case .pasteFailed: return String(localized: "Paste command failed")
        case .pasteNotVerified: return String(localized: "Paste could not be verified")
        case .autoSent: return String(localized: "Auto-sent; editing not observed")
        case .observing: return String(localized: "Watching for edits")
        case .unchanged: return String(localized: "No edits detected")
        case .edited: return String(localized: "Edited after paste")
        case .superseded: return String(localized: "Stopped by a newer paste")
        case .timedOut: return String(localized: "Observation finished")
        }
    }
}

struct TranscriptionEditRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let removedText: String
    let insertedText: String
    let resultingText: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        removedText: String,
        insertedText: String,
        resultingText: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.removedText = removedText
        self.insertedText = insertedText
        self.resultingText = resultingText
    }
}

extension Transcription {
    var hasPostPasteEdits: Bool {
        !postPasteEditRecords.isEmpty
    }

    var preferredHistoryDisplayText: String {
        if hasPostPasteEdits, let finalEditedText, !finalEditedText.isEmpty {
            return finalEditedText
        }
        return enhancedText ?? text
    }

    var pasteTrackingStatusValue: PasteTrackingStatus? {
        get {
            guard let pasteTrackingStatus else { return nil }
            return PasteTrackingStatus(rawValue: pasteTrackingStatus)
        }
        set {
            pasteTrackingStatus = newValue?.rawValue
        }
    }

    var postPasteEditRecords: [TranscriptionEditRecord] {
        get {
            guard let postPasteEditHistoryData else { return [] }
            return (try? JSONDecoder().decode([TranscriptionEditRecord].self, from: postPasteEditHistoryData)) ?? []
        }
        set {
            postPasteEditHistoryData = try? JSONEncoder().encode(newValue)
        }
    }

    func appendPostPasteEditRecord(_ record: TranscriptionEditRecord, maximumCount: Int = 50) {
        var records = postPasteEditRecords
        records.append(record)
        if records.count > maximumCount {
            records.removeFirst(records.count - maximumCount)
        }
        postPasteEditRecords = records
    }
}
