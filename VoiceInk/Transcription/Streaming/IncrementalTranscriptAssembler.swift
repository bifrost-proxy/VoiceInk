import Foundation

/// Keeps finalized streaming windows and the current hypothesis as one cumulative transcript.
/// Buffered local ASR models revise the current window on every pass, so only finalized windows
/// are appended permanently.
struct IncrementalTranscriptAssembler {
    private(set) var finalizedText = ""
    private(set) var partialText = ""

    var displayText: String {
        Self.merge(finalizedText, partialText)
    }

    mutating func updatePartial(_ text: String) -> String {
        let candidate = Self.trim(text)
        if candidate.isEmpty {
            return displayText
        }

        // Do not let a shorter prefix from a later decode make live text jump backwards.
        if partialText.hasPrefix(candidate) {
            return displayText
        }

        partialText = candidate
        return displayText
    }

    mutating func finalize(_ text: String) -> String {
        let candidate = Self.bestFinalCandidate(newText: text, previousPartial: partialText)
        if !candidate.isEmpty {
            finalizedText = Self.merge(finalizedText, candidate)
        }
        partialText = ""
        return finalizedText
    }

    mutating func reset() {
        finalizedText = ""
        partialText = ""
    }

    static func merge(_ existing: String, _ incoming: String) -> String {
        let existing = trim(existing)
        let incoming = trim(incoming)
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        if incoming == existing || existing.hasSuffix(incoming) {
            return existing
        }
        if incoming.hasPrefix(existing) {
            return incoming
        }

        let left = Array(existing)
        let right = Array(incoming)
        let maximumOverlap = min(32, min(left.count, right.count))
        if maximumOverlap >= 2 {
            for count in stride(from: maximumOverlap, through: 2, by: -1) {
                if left.suffix(count).elementsEqual(right.prefix(count)) {
                    return existing + String(right.dropFirst(count))
                }
            }
        }

        // A one-character overlap is too ambiguous for English, but is common
        // at a Chinese phrase boundary (for example: "刚" + "刚我...").
        if left.last == right.first, left.last?.isASCII == false {
            return existing + String(right.dropFirst())
        }

        return join(existing, incoming)
    }

    private static func bestFinalCandidate(newText: String, previousPartial: String) -> String {
        let newText = trim(newText)
        let previousPartial = trim(previousPartial)
        guard !newText.isEmpty else { return previousPartial }
        guard !previousPartial.isEmpty else { return newText }

        if previousPartial.hasPrefix(newText) {
            return previousPartial
        }
        return newText
    }

    private static func join(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        guard let last = left.last, let first = right.first else { return left + right }

        if last.isWhitespace || first.isWhitespace || first.isPunctuation {
            return left + right
        }

        if last.isPunctuation {
            let needsSpace = last.isASCII && first.isASCII && first.isLetterOrNumber
            return left + (needsSpace ? " " : "") + right
        }

        let needsSpace = last.isASCII && first.isASCII && last.isLetterOrNumber && first.isLetterOrNumber
        return left + (needsSpace ? " " : "") + right
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    var isASCII: Bool {
        unicodeScalars.allSatisfy(\.isASCII)
    }

    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    var isPunctuation: Bool {
        unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
