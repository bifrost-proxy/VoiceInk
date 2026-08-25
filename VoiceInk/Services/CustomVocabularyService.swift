import Foundation
import SwiftData
import SwiftUI

class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func getCustomVocabulary(from context: ModelContext) -> String {
        let entries = TranscriptionVocabularyContext.entries(from: context)
        return getCustomVocabulary(terms: entries.map(\.term))
    }

    func getCustomVocabulary(terms: [String]) -> String {
        var seen = Set<String>()
        let normalized = terms.compactMap { value -> String? in
            let term = value.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty,
                seen.insert(TranscriptionVocabularyContext.normalizedKey(term)).inserted
            else { return nil }
            return term
        }
        guard !normalized.isEmpty else { return "" }
        return "Important Vocabulary: \(normalized.joined(separator: ", "))"
    }
}
