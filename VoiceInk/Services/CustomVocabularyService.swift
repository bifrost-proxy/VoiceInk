import Foundation
import SwiftData
import SwiftUI

class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func getCustomVocabulary(from context: ModelContext) -> String {
        let entries = TranscriptionVocabularyContext.entries(from: context)
        guard !entries.isEmpty else { return "" }

        let terms = entries.map(\.term).joined(separator: ", ")
        return "Important Vocabulary: \(terms)"
    }
}
