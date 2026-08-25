import Foundation
import SwiftData

enum TranscriptionVocabularySource: Equatable, Sendable {
    case domain(String)
    case application(String)
    case global
}

struct TranscriptionVocabularyContextEntry: Equatable, Sendable {
    let term: String
    let source: TranscriptionVocabularySource

    init(term: String, source: TranscriptionVocabularySource = .global) {
        self.term = term
        self.source = source
    }
}

struct VocabularyUsageContext: Equatable, Sendable {
    let bundleIdentifier: String?
    let applicationName: String?
    let domain: String?

    static let none = VocabularyUsageContext(
        bundleIdentifier: nil,
        applicationName: nil,
        domain: nil
    )

    init(bundleIdentifier: String?, applicationName: String?, domain: String?) {
        self.bundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        self.applicationName = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.domain = VocabularyDomain.normalizedHost(from: domain)
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct ResolvedVocabulary: Equatable, Sendable {
    let terms: [String]
    let applicableTerms: [String]
    let domainUsed: Int
    let applicationUsed: Int
    let globalUsed: Int
    let omittedCount: Int
    let maximumCount: Int?

    static let empty = ResolvedVocabulary(
        terms: [],
        applicableTerms: [],
        domainUsed: 0,
        applicationUsed: 0,
        globalUsed: 0,
        omittedCount: 0,
        maximumCount: nil
    )
}

enum VocabularyDomain {
    static func normalizedHost(from value: String?) -> String? {
        guard let value else { return nil }
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard let components = URLComponents(string: candidate), var host = components.host else {
            return nil
        }
        host = host.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }

    static func matches(host: String, configuredDomain: String) -> Bool {
        host == configuredDomain || host.hasSuffix(".\(configuredDomain)")
    }
}

enum TranscriptionVocabularyCapability {
    static func supportsVocabulary(
        for model: any TranscriptionModel,
        isRealtimeEnabled: Bool
    ) -> Bool {
        switch model.provider {
        case .elevenLabs, .soniox, .speechmatics, .assemblyAI, .doubaoSpeech, .aliyunQwen:
            return true
        case .deepgram:
            // Deepgram only consumes the configured keywords on its streaming path.
            return isRealtimeEnabled
        case .whisper, .fluidAudio, .sherpaOnnx, .qwenMlx, .groq, .mistral, .gemini,
            .xai, .nativeApple, .custom, .cartesia:
            return false
        }
    }

    static func maximumCount(for model: any TranscriptionModel) -> Int? {
        switch model.provider {
        case .deepgram, .doubaoSpeech:
            return 50
        default:
            return nil
        }
    }
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

    static func hasDomainVocabulary(in modelContext: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<ScopedVocabularyWord>(
            predicate: #Predicate { $0.scopeKindRaw == "domain" }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor))?.isEmpty == false)
    }

    static func resolve(
        from modelContext: ModelContext,
        usageContext: VocabularyUsageContext,
        model: any TranscriptionModel,
        isRealtimeEnabled: Bool
    ) -> ResolvedVocabulary {
        let candidates = applicableEntries(from: modelContext, usageContext: usageContext)
        let applicableTerms = candidates.map(\.term)

        guard TranscriptionVocabularyCapability.supportsVocabulary(
            for: model,
            isRealtimeEnabled: isRealtimeEnabled
        ) else {
            return ResolvedVocabulary(
                terms: [],
                applicableTerms: applicableTerms,
                domainUsed: 0,
                applicationUsed: 0,
                globalUsed: 0,
                omittedCount: applicableTerms.count,
                maximumCount: 0
            )
        }

        let maximumCount = TranscriptionVocabularyCapability.maximumCount(for: model)
        let selected = maximumCount.map { Array(candidates.prefix($0)) } ?? candidates
        var domainUsed = 0
        var applicationUsed = 0
        var globalUsed = 0
        for entry in selected {
            switch entry.source {
            case .domain:
                domainUsed += 1
            case .application:
                applicationUsed += 1
            case .global:
                globalUsed += 1
            }
        }

        return ResolvedVocabulary(
            terms: selected.map(\.term),
            applicableTerms: applicableTerms,
            domainUsed: domainUsed,
            applicationUsed: applicationUsed,
            globalUsed: globalUsed,
            omittedCount: candidates.count - selected.count,
            maximumCount: maximumCount
        )
    }

    static func applicableEntries(
        from modelContext: ModelContext,
        usageContext: VocabularyUsageContext
    ) -> [TranscriptionVocabularyContextEntry] {
        let scopedDescriptor = FetchDescriptor<ScopedVocabularyWord>(
            sortBy: [SortDescriptor(\.word)]
        )
        let scopedItems = (try? modelContext.fetch(scopedDescriptor)) ?? []

        let domainEntries: [(specificity: Int, entry: TranscriptionVocabularyContextEntry)] =
            scopedItems.compactMap { item in
                guard item.scopeKind == .domain,
                    let activeDomain = usageContext.domain,
                    let configuredDomain = VocabularyDomain.normalizedHost(from: item.scopeIdentifier),
                    VocabularyDomain.matches(host: activeDomain, configuredDomain: configuredDomain),
                    let term = normalizedTerm(item.word)
                else { return nil }
                return (
                    configuredDomain.count,
                    TranscriptionVocabularyContextEntry(term: term, source: .domain(configuredDomain))
                )
            }
            .sorted { lhs, rhs in
                if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
                return lhs.entry.term.localizedCaseInsensitiveCompare(rhs.entry.term) == .orderedAscending
            }

        let applicationEntries = scopedItems.compactMap { item -> TranscriptionVocabularyContextEntry? in
            guard item.scopeKind == .application,
                let bundleIdentifier = usageContext.bundleIdentifier,
                item.scopeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == bundleIdentifier,
                let term = normalizedTerm(item.word)
            else { return nil }
            return TranscriptionVocabularyContextEntry(term: term, source: .application(bundleIdentifier))
        }

        let combined = domainEntries.map { $0.entry } + applicationEntries + entries(from: modelContext)
        var seen = Set<String>()
        return combined.filter { seen.insert(normalizedKey($0.term)).inserted }
    }

    static func normalizedKey(_ term: String) -> String {
        term.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func normalizedTerm(_ value: String) -> String? {
        let term = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? nil : term
    }
}
