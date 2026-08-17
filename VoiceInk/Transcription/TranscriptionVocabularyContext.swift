import Foundation
import SwiftData

struct TranscriptionVocabularyContextEntry: Equatable, Sendable {
    let term: String
}

/// Provider-neutral access to the user's transcription vocabulary. Providers
/// can consume `uniqueTerms` for hotword APIs or inspect normalized `entries`.
enum TranscriptionVocabularyContext {
    static func entries(from modelContext: ModelContext) -> [TranscriptionVocabularyContextEntry] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let items = try? modelContext.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        return items.compactMap { item in
            let term = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return TranscriptionVocabularyContextEntry(term: term)
        }
    }

    static func uniqueTerms(from modelContext: ModelContext) -> [String] {
        entries(from: modelContext).map(\.term)
    }
}
