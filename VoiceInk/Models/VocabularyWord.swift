import Foundation
import SwiftData

enum VocabularyEntryKind: String, Codable, CaseIterable, Sendable {
    case vocabulary
    case properNoun
}

@Model
final class VocabularyWord {
    var word: String = ""
    var dateAdded: Date = Date()
    var kindRawValue: String = VocabularyEntryKind.vocabulary.rawValue

    init(
        word: String,
        dateAdded: Date = Date(),
        kind: VocabularyEntryKind = .vocabulary
    ) {
        self.word = word
        self.dateAdded = dateAdded
        kindRawValue = kind.rawValue
    }

    var kind: VocabularyEntryKind {
        get { VocabularyEntryKind(rawValue: kindRawValue) ?? .vocabulary }
        set { kindRawValue = newValue.rawValue }
    }
}
