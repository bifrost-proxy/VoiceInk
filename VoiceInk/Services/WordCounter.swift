import NaturalLanguage

struct WordCounter {
    static let currentVersion = 2

    /// Han characters count individually; other text retains word segmentation.
    /// Replacing Han with spaces also separates adjacent English and Chinese.
    static func count(in text: String) -> Int {
        var hanCount = 0
        var remaining = String.UnicodeScalarView()
        remaining.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                hanCount += 1
                remaining.append(" ")
            } else {
                remaining.append(scalar)
            }
        }
        let tokenizer = NLTokenizer(unit: .word)
        let nonHanText = String(remaining)
        tokenizer.string = nonHanText
        var words = 0
        tokenizer.enumerateTokens(in: nonHanText.startIndex..<nonHanText.endIndex) { range, _ in
            if nonHanText[range].unicodeScalars.contains(where: {
                CharacterSet.alphanumerics.contains($0)
            }) {
                words += 1
            }
            return true
        }
        return hanCount + words
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
            0x20000...0x2EE5F, 0x2F800...0x2FA1F, 0x30000...0x3347F:
            return true
        default:
            return false
        }
    }
}
