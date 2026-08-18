import Foundation

struct RecognitionContextPermissions: Equatable, Sendable {
    var selectedText = false
    var clipboard = false
    var application = false
    var windowTitle = false

    var sources: Set<ContextSource> {
        var result = Set<ContextSource>()
        if selectedText { result.insert(.selectedText) }
        if clipboard { result.insert(.clipboard) }
        if application { result.insert(.application) }
        if windowTitle { result.insert(.windowTitle) }
        return result
    }
}

struct RecognitionContextProviderConfiguration: Equatable, Sendable {
    let permissions: RecognitionContextPermissions
    let configuredScenario: String?

    static func current(for provider: ModelProvider) -> Self? {
        switch provider {
        case .aliyunQwen:
            let settings = AliyunQwenSpeechSettings.current()
            return RecognitionContextProviderConfiguration(
                permissions: settings.recognitionContextPermissions,
                configuredScenario: normalized(settings.contextPrompt)
            )
        case .doubaoSpeech:
            let settings = DoubaoSpeechSettings.current()
            return RecognitionContextProviderConfiguration(
                permissions: settings.recognitionContextPermissions,
                configuredScenario: normalized(settings.contextPrompt)
            )
        default:
            return nil
        }
    }

    private static func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct RecognitionContextEnvelope: Equatable, Sendable {
    let capturedAt: Date
    let applicationName: String?
    let windowTitle: String?
    let configuredScenario: String?
    let features: [ContextFeature]

    var isEmpty: Bool {
        applicationName == nil && windowTitle == nil && configuredScenario == nil && features.isEmpty
    }

    func features(from source: ContextSource) -> [ContextFeature] {
        features.filter { $0.sources.contains(source) }
    }
}

struct RecognitionContextSerialization: Equatable, Sendable {
    let value: String?
    let includedSources: Set<ContextSource>
    let featureCounts: [ContextSource: Int]
    let itemCount: Int
    let estimatedTokens: Int
    let truncated: Bool
}

enum RecognitionContextLogSummary {
    static func make(
        provider: ModelProvider,
        serialization: RecognitionContextSerialization,
        hotwordCount: Int
    ) -> String {
        let sourceNames = serialization.includedSources.map(\.rawValue).sorted().joined(separator: ",")
        return "Recognition context prepared provider=\(String(describing: provider)) "
            + "sources=\(sourceNames) "
            + "featureCounts=selected:\(serialization.featureCounts[.selectedText, default: 0]),"
            + "clipboard:\(serialization.featureCounts[.clipboard, default: 0]) "
            + "applicationIncluded=\(serialization.includedSources.contains(.application)) "
            + "windowTitleIncluded=\(serialization.includedSources.contains(.windowTitle)) "
            + "contextItems=\(serialization.itemCount) estimatedTokens=\(serialization.estimatedTokens) "
            + "truncated=\(serialization.truncated) hotwordCount=\(hotwordCount)"
    }
}

enum RecognitionContextPolicy {
    static func asrSources(
        mode: ModeConfig,
        providerConfiguration: RecognitionContextProviderConfiguration?
    ) -> Set<ContextSource> {
        guard let permissions = providerConfiguration?.permissions else { return [] }
        var sources = Set<ContextSource>()
        if mode.useSelectedTextContext, permissions.selectedText { sources.insert(.selectedText) }
        if mode.useClipboardContext, permissions.clipboard { sources.insert(.clipboard) }
        if mode.useActiveApplicationContext, permissions.application { sources.insert(.application) }
        if mode.useWindowTitleContext, permissions.windowTitle { sources.insert(.windowTitle) }
        if providerConfiguration?.configuredScenario != nil { sources.insert(.configuredScenario) }
        return sources
    }

    static func capturePlan(
        mode: ModeConfig,
        providerConfiguration: RecognitionContextProviderConfiguration?
    ) -> RecordingContextCapturePlan {
        var sources = asrSources(mode: mode, providerConfiguration: providerConfiguration)
        if mode.isAIEnhancementEnabled {
            if mode.useSelectedTextContext { sources.insert(.selectedText) }
            if mode.useClipboardContext { sources.insert(.clipboard) }
            if mode.useActiveApplicationContext { sources.insert(.application) }
            if mode.useWindowTitleContext { sources.insert(.windowTitle) }
            if mode.useScreenCapture { sources.insert(.screenOCR) }
        }
        return RecordingContextCapturePlan(sources: sources)
    }
}

enum SpeechRecognitionContextBuilder {
    static func build(
        snapshot: RecordingContextSnapshot,
        mode: ModeConfig,
        providerConfiguration: RecognitionContextProviderConfiguration
    ) -> RecognitionContextEnvelope? {
        let sources = RecognitionContextPolicy.asrSources(
            mode: mode,
            providerConfiguration: providerConfiguration
        )
        var featureInputs: [(ContextSource, String, Int)] = []
        if sources.contains(.selectedText), let text = snapshot.selectedText {
            featureInputs.append((.selectedText, text, 90))
        }
        if sources.contains(.clipboard), let text = snapshot.clipboardText {
            featureInputs.append((.clipboard, text, 50))
        }
        let envelope = RecognitionContextEnvelope(
            capturedAt: snapshot.capturedAt,
            applicationName: sources.contains(.application) ? snapshot.activeSurface?.applicationName : nil,
            windowTitle: sources.contains(.windowTitle) ? snapshot.activeSurface?.windowTitle : nil,
            configuredScenario: sources.contains(.configuredScenario)
                ? providerConfiguration.configuredScenario
                : nil,
            features: ContextFeatureExtractor.extract(from: featureInputs)
        )
        return envelope.isEmpty ? nil : envelope
    }
}

enum ContextFeatureExtractor {
    private static let expression = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9_./+#-]{1,63}|[\p{Han}]{2,12}"#
    )
    private static let excludedTerms: Set<String> = [
        "active window", "application", "window content", "no text detected via ocr",
    ]

    static func extract(from inputs: [(source: ContextSource, text: String, priority: Int)]) -> [ContextFeature] {
        var features: [String: ContextFeature] = [:]
        var order: [String] = []

        for input in inputs {
            let withoutInternalLabels = input.text.precomposedStringWithCanonicalMapping
                .replacingOccurrences(
                    of: #"(?im)^\s*(Active Window|Application|Window Content)\s*:"#,
                    with: " ",
                    options: .regularExpression
                )
            let normalizedText = withoutInternalLabels
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let range = NSRange(normalizedText.startIndex..., in: normalizedText)
            for match in expression.matches(in: normalizedText, range: range) {
                guard let range = Range(match.range, in: normalizedText) else { continue }
                let value = String(normalizedText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard !value.isEmpty, !excludedTerms.contains(key) else { continue }
                if var existing = features[key] {
                    existing.sources.insert(input.source)
                    features[key] = ContextFeature(
                        value: existing.value,
                        sources: existing.sources,
                        priority: max(existing.priority, input.priority)
                    )
                } else {
                    features[key] = ContextFeature(
                        value: value,
                        sources: [input.source],
                        priority: input.priority
                    )
                    order.append(key)
                }
            }
        }

        return order.compactMap { features[$0] }
            .sorted { first, second in
                first.priority == second.priority
                    ? order.firstIndex(of: normalizedKey(first.value))! < order.firstIndex(of: normalizedKey(second.value))!
                    : first.priority > second.priority
            }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum QwenRecognitionContextSerializer {
    static let maximumLength = AliyunQwenSpeechSettings.maximumContextLength

    static func serialize(
        _ envelope: RecognitionContextEnvelope?,
        fallbackScenario: String? = nil
    ) -> RecognitionContextSerialization {
        let fallbackScenario = fallbackScenario?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveEnvelope = envelope ?? fallbackScenario.flatMap { scenario in
            guard !scenario.isEmpty else { return nil }
            return RecognitionContextEnvelope(
                capturedAt: Date(), applicationName: nil, windowTitle: nil,
                configuredScenario: scenario, features: []
            )
        }
        guard let envelope = effectiveEnvelope else {
            return RecognitionContextSerialization(
                value: nil, includedSources: [], featureCounts: [:], itemCount: 0,
                estimatedTokens: 0, truncated: false
            )
        }

        var output = ""
        var includedSources = Set<ContextSource>()
        var featureCounts: [ContextSource: Int] = [:]
        var itemCount = 0
        var truncated = false

        func normalizedMetadataValue(_ value: String?, maximumLength: Int? = nil) -> String? {
            guard let value else { return nil }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            if let maximumLength, normalized.count > maximumLength { truncated = true }
            return maximumLength.map { String(normalized.prefix($0)) } ?? normalized
        }

        func appendMetadata(label: String, value: String?, source: ContextSource, maximumValueLength: Int? = nil) {
            guard let limited = normalizedMetadataValue(value, maximumLength: maximumValueLength) else { return }
            let segment = "[\(label)] \(limited)"
            let candidate = output.isEmpty ? segment : "\(output) \(segment)"
            guard candidate.count <= maximumLength else {
                truncated = true
                return
            }
            output = candidate
            includedSources.insert(source)
            itemCount += 1
        }

        func appendFeatures(label: String, sources: Set<ContextSource>, features: [ContextFeature]) {
            guard !features.isEmpty else { return }
            var values: [String] = []
            for feature in features {
                let nextValues = values + [feature.value]
                let segment = "[\(label)] \(nextValues.joined(separator: ", "))"
                let candidate = output.isEmpty ? segment : "\(output) \(segment)"
                if candidate.count > maximumLength {
                    truncated = true
                    break
                }
                values = nextValues
            }
            guard !values.isEmpty else { return }
            let segment = "[\(label)] \(values.joined(separator: ", "))"
            output = output.isEmpty ? segment : "\(output) \(segment)"
            includedSources.formUnion(sources)
            for source in sources {
                featureCounts[source, default: 0] += values.count
            }
            itemCount += 1
        }

        let applicationValue = normalizedMetadataValue(envelope.applicationName, maximumLength: 40)
        let windowTitleValue = normalizedMetadataValue(envelope.windowTitle, maximumLength: 56)
        let reservedSurfaceSegments = [
            applicationValue.map { "[应用] \($0)" },
            windowTitleValue.map { "[窗口] \($0)" },
        ].compactMap { $0 }
        let reservedSurfaceLength = reservedSurfaceSegments.joined(separator: " ").count
        let scenarioLabelLength = "[场景] ".count
        let scenarioSeparatorLength = reservedSurfaceSegments.isEmpty ? 0 : 1
        let scenarioBudget = max(
            0,
            maximumLength - reservedSurfaceLength - scenarioSeparatorLength - scenarioLabelLength
        )
        let fullScenario = normalizedMetadataValue(envelope.configuredScenario)
        let scenarioValue = fullScenario.map { String($0.prefix(scenarioBudget)) }
        if let fullScenario, fullScenario.count > scenarioBudget { truncated = true }

        appendMetadata(label: "场景", value: scenarioValue, source: .configuredScenario)
        appendMetadata(label: "应用", value: applicationValue, source: .application)
        appendMetadata(label: "窗口", value: windowTitleValue, source: .windowTitle)
        for group in groupedFeatures(
            envelope.features,
            sourceOrder: [.selectedText, .clipboard]
        ) {
            let label = group.sources
                .sorted { sourceRank($0, in: [.selectedText, .clipboard]) < sourceRank($1, in: [.selectedText, .clipboard]) }
                .map(qwenSourceLabel)
                .joined(separator: "+") + "关键词"
            appendFeatures(label: label, sources: group.sources, features: group.features)
        }

        return RecognitionContextSerialization(
            value: output.isEmpty ? nil : output,
            includedSources: includedSources,
            featureCounts: featureCounts,
            itemCount: itemCount,
            estimatedTokens: estimatedTokenCount(output),
            truncated: truncated
        )
    }
}

enum DoubaoRecognitionContextSerializer {
    static let maximumItems = 8
    static let maximumEstimatedTokens = 600

    static func serialize(
        _ envelope: RecognitionContextEnvelope?,
        fallbackScenario: String? = nil
    ) -> RecognitionContextSerialization {
        let fallbackScenario = fallbackScenario?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveEnvelope = envelope ?? fallbackScenario.flatMap { scenario in
            guard !scenario.isEmpty else { return nil }
            return RecognitionContextEnvelope(
                capturedAt: Date(), applicationName: nil, windowTitle: nil,
                configuredScenario: scenario, features: []
            )
        }
        guard let envelope = effectiveEnvelope else {
            return RecognitionContextSerialization(
                value: nil, includedSources: [], featureCounts: [:], itemCount: 0,
                estimatedTokens: 0, truncated: false
            )
        }

        var entries: [String] = []
        var includedSources = Set<ContextSource>()
        var featureCounts: [ContextSource: Int] = [:]
        var truncated = false

        func encodedValue(for candidateEntries: [String]) -> String? {
            let object: [String: Any] = [
                "context_type": "dialog_ctx",
                "context_data": candidateEntries.map { ["text": $0] },
            ]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }

        func fits(_ candidateEntries: [String]) -> Bool {
            guard candidateEntries.count <= maximumItems,
                let value = encodedValue(for: candidateEntries)
            else { return false }
            return estimatedTokenCount(value) <= maximumEstimatedTokens
        }

        func appendEntry(_ text: String, sources: Set<ContextSource>, counts: [ContextSource: Int] = [:]) {
            let candidate = entries + [text]
            guard fits(candidate) else {
                truncated = true
                return
            }
            entries = candidate
            includedSources.formUnion(sources)
            for (source, count) in counts { featureCounts[source, default: 0] += count }
        }

        func appendFeatureEntry(prefix: String, sources: Set<ContextSource>, features: [ContextFeature]) {
            guard !features.isEmpty else { return }
            var values: [String] = []
            for feature in features {
                let candidate = values + [feature.value]
                let text = "\(prefix)：\(candidate.joined(separator: "、"))"
                if fits(entries + [text]) {
                    values = candidate
                } else {
                    truncated = true
                    break
                }
            }
            guard !values.isEmpty else { return }
            appendEntry(
                "\(prefix)：\(values.joined(separator: "、"))",
                sources: sources,
                counts: Dictionary(uniqueKeysWithValues: sources.map { ($0, values.count) })
            )
        }

        let doubaoSourceOrder: [ContextSource] = [.selectedText, .clipboard]
        let featureGroups = groupedFeatures(envelope.features, sourceOrder: doubaoSourceOrder)
        func appendFeatureGroups(primarySource: ContextSource) {
            for group in featureGroups
            where group.sources.min(by: {
                sourceRank($0, in: doubaoSourceOrder) < sourceRank($1, in: doubaoSourceOrder)
            }) == primarySource {
                let prefix = group.sources
                    .sorted { sourceRank($0, in: doubaoSourceOrder) < sourceRank($1, in: doubaoSourceOrder) }
                    .map(doubaoSourceLabel)
                    .joined(separator: "及") + "关键词"
                appendFeatureEntry(prefix: prefix, sources: group.sources, features: group.features)
            }
        }

        appendFeatureGroups(primarySource: .selectedText)
        if envelope.applicationName != nil || envelope.windowTitle != nil {
            let components = [
                envelope.applicationName.map { "当前应用：\($0)" },
                envelope.windowTitle.map { "窗口：\($0)" },
            ].compactMap { $0 }
            var sources = Set<ContextSource>()
            if envelope.applicationName != nil { sources.insert(.application) }
            if envelope.windowTitle != nil { sources.insert(.windowTitle) }
            appendEntry(components.joined(separator: "；"), sources: sources)
        }
        appendFeatureGroups(primarySource: .clipboard)
        if let scenario = envelope.configuredScenario {
            appendEntry("业务场景：\(scenario)", sources: [.configuredScenario])
        }

        let value = encodedValue(for: entries)
        return RecognitionContextSerialization(
            value: entries.isEmpty ? nil : value,
            includedSources: includedSources,
            featureCounts: featureCounts,
            itemCount: entries.count,
            estimatedTokens: estimatedTokenCount(value ?? ""),
            truncated: truncated
        )
    }
}

private struct ContextFeatureGroup {
    let sources: Set<ContextSource>
    var features: [ContextFeature]
    let firstIndex: Int
}

private func groupedFeatures(
    _ features: [ContextFeature],
    sourceOrder: [ContextSource]
) -> [ContextFeatureGroup] {
    let eligibleSources = Set(sourceOrder)
    var groups: [Set<ContextSource>: ContextFeatureGroup] = [:]
    for (index, feature) in features.enumerated() {
        let sources = feature.sources.intersection(eligibleSources)
        guard !sources.isEmpty else { continue }
        if var group = groups[sources] {
            group.features.append(feature)
            groups[sources] = group
        } else {
            groups[sources] = ContextFeatureGroup(
                sources: sources,
                features: [feature],
                firstIndex: index
            )
        }
    }
    return groups.values.sorted { first, second in
        let firstRank = first.sources.map { sourceRank($0, in: sourceOrder) }.min() ?? Int.max
        let secondRank = second.sources.map { sourceRank($0, in: sourceOrder) }.min() ?? Int.max
        return firstRank == secondRank ? first.firstIndex < second.firstIndex : firstRank < secondRank
    }
}

private func sourceRank(_ source: ContextSource, in order: [ContextSource]) -> Int {
    order.firstIndex(of: source) ?? Int.max
}

private func qwenSourceLabel(_ source: ContextSource) -> String {
    switch source {
    case .selectedText: "选中文本"
    case .clipboard: "剪贴板"
    default: source.rawValue
    }
}

private func doubaoSourceLabel(_ source: ContextSource) -> String {
    switch source {
    case .selectedText: "用户当前选中文本"
    case .clipboard: "当前剪贴板"
    default: source.rawValue
    }
}

private func estimatedTokenCount(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    // Conservative for mixed CJK/Latin recognition hints; keeps well below the server's 800-token cap.
    return Int(ceil(Double(text.count) / 2.0))
}
