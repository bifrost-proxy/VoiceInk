import Foundation
import SwiftData

enum VocabularyScopeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case application
    case domain
}

struct VocabularyScopeSelection: Hashable, Identifiable, Sendable {
    let kind: VocabularyScopeKind
    let identifier: String
    let displayName: String

    var id: String { "\(kind.rawValue):\(identifier)" }

    init?(kind: VocabularyScopeKind, identifier: String, displayName: String? = nil) {
        let normalizedIdentifier: String?
        switch kind {
        case .application:
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            normalizedIdentifier = value.isEmpty ? nil : value
        case .domain:
            normalizedIdentifier = VocabularyDomain.normalizedHost(from: identifier)
        }
        guard let normalizedIdentifier else { return nil }
        self.kind = kind
        self.identifier = normalizedIdentifier
        let normalizedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedDisplayName?.isEmpty == false ? normalizedDisplayName! : normalizedIdentifier
    }
}

@Model
final class ScopedVocabularyWord {
    var id: UUID = UUID()
    var word: String = ""
    var scopeKindRaw: String = VocabularyScopeKind.application.rawValue
    var scopeIdentifier: String = ""
    var scopeDisplayName: String?
    var dateAdded: Date = Date()

    var scopeKind: VocabularyScopeKind? {
        VocabularyScopeKind(rawValue: scopeKindRaw)
    }

    init(
        id: UUID = UUID(),
        word: String,
        scopeKind: VocabularyScopeKind,
        scopeIdentifier: String,
        scopeDisplayName: String? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.word = word
        self.scopeKindRaw = scopeKind.rawValue
        self.scopeIdentifier = scopeIdentifier
        self.scopeDisplayName = scopeDisplayName
        self.dateAdded = dateAdded
    }
}
