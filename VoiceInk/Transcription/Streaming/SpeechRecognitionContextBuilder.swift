import Foundation

enum SpeechRecognitionContextBuilder {
    static func build(
        snapshot: RecordingContextSnapshot,
        mode: ModeConfig,
        settings: AliyunQwenSpeechSettings
    ) -> String? {
        var sourceTexts: [String] = []
        if mode.useSelectedTextContext, settings.useSelectedTextContext,
            let selectedText = snapshot.selectedText
        {
            sourceTexts.append(selectedText)
        }
        if mode.useClipboardContext, settings.useClipboardContext,
            let clipboardText = snapshot.clipboardText
        {
            sourceTexts.append(clipboardText)
        }
        if mode.useScreenCapture, settings.useScreenContext,
            let screenText = snapshot.screenText
        {
            sourceTexts.append(screenText)
        }

        var seen = Set<String>()
        var terms: [String] = []
        for source in sourceTexts {
            for term in extractTerms(from: source) {
                let key = term.lowercased()
                guard seen.insert(key).inserted else { continue }
                terms.append(term)
                if terms.count >= 40 { break }
            }
            if terms.count >= 40 { break }
        }

        var result = ""
        for term in terms {
            let candidate = result.isEmpty ? term : "\(result)、\(term)"
            guard candidate.count <= AliyunQwenSpeechSettings.maximumContextLength else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }

    private static func extractTerms(from text: String) -> [String] {
        let pattern = #"[A-Za-z][A-Za-z0-9_./+#-]{1,63}|[\p{Han}]{2,12}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}
