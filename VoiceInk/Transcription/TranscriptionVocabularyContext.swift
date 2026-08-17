import Foundation
import SwiftData

struct TranscriptionVocabularyContextEntry: Equatable, Sendable {
    let term: String
    let kind: VocabularyEntryKind
}

/// Provider-neutral access to the user's transcription vocabulary. Providers
/// can consume `uniqueTerms` for hotword APIs or inspect `entries` when they
/// need to distinguish ordinary vocabulary from proper nouns.
enum TranscriptionVocabularyContext {
    static func entries(from modelContext: ModelContext) -> [TranscriptionVocabularyContextEntry] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let items = try? modelContext.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        return items.compactMap { item in
            let term = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return TranscriptionVocabularyContextEntry(
                term: term,
                kind: item.kind
            )
        }
    }

    static func uniqueTerms(from modelContext: ModelContext) -> [String] {
        entries(from: modelContext).map(\.term)
    }
}
