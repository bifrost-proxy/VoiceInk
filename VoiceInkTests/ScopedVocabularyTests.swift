import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct ScopedVocabularyTests {
    @Test func normalizesAndMatchesDomainsAtLabelBoundaries() {
        #expect(VocabularyDomain.normalizedHost(from: " HTTPS://Docs.Example.com:443/path?q=1 ") == "docs.example.com")
        #expect(VocabularyDomain.normalizedHost(from: "example.com.") == "example.com")
        #expect(VocabularyDomain.matches(host: "docs.example.com", configuredDomain: "example.com"))
        #expect(VocabularyDomain.matches(host: "example.com", configuredDomain: "example.com"))
        #expect(!VocabularyDomain.matches(host: "notexample.com", configuredDomain: "example.com"))
    }

    @Test func domainThenApplicationThenGlobalFillARestrictedModelBudget() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<40 {
            context.insert(VocabularyWord(word: String(format: "global-%02d", index)))
        }
        for index in 0..<20 {
            context.insert(
                ScopedVocabularyWord(
                    word: String(format: "app-%02d", index),
                    scopeKind: .application,
                    scopeIdentifier: "com.example.browser",
                    scopeDisplayName: "Browser"
                )
            )
        }
        for index in 0..<15 {
            context.insert(
                ScopedVocabularyWord(
                    word: String(format: "domain-%02d", index),
                    scopeKind: .domain,
                    scopeIdentifier: "docs.example.com"
                )
            )
        }
        try context.save()

        let resolved = TranscriptionVocabularyContext.resolve(
            from: context,
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "COM.EXAMPLE.BROWSER",
                applicationName: "Browser",
                domain: "https://docs.example.com/project"
            ),
            model: restrictedModel,
            isRealtimeEnabled: true
        )

        #expect(resolved.terms.count == 50)
        #expect(resolved.domainUsed == 15)
        #expect(resolved.applicationUsed == 20)
        #expect(resolved.globalUsed == 15)
        #expect(resolved.omittedCount == 25)
        #expect(resolved.terms.prefix(15).allSatisfy { $0.hasPrefix("domain-") })
        #expect(resolved.terms.dropFirst(15).prefix(20).allSatisfy { $0.hasPrefix("app-") })
    }

    @Test func duplicateTermUsesTheMostSpecificSourceAndOneBudgetSlot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(VocabularyWord(word: "VoiceInk"))
        context.insert(
            ScopedVocabularyWord(
                word: "voiceink",
                scopeKind: .application,
                scopeIdentifier: "com.example.editor"
            )
        )
        context.insert(
            ScopedVocabularyWord(
                word: "VOICEINK",
                scopeKind: .domain,
                scopeIdentifier: "example.com"
            )
        )
        try context.save()

        let entries = TranscriptionVocabularyContext.applicableEntries(
            from: context,
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.example.editor",
                applicationName: "Editor",
                domain: "docs.example.com"
            )
        )
        #expect(entries.count == 1)
        #expect(entries.first?.source == .domain("example.com"))
    }

    @Test func unsupportedASRStillExposesApplicableTermsForEnhancement() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(VocabularyWord(word: "Global"))
        context.insert(
            ScopedVocabularyWord(
                word: "Local",
                scopeKind: .application,
                scopeIdentifier: "com.example.editor"
            )
        )
        try context.save()

        let resolved = TranscriptionVocabularyContext.resolve(
            from: context,
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.example.editor",
                applicationName: "Editor",
                domain: nil
            ),
            model: unsupportedModel,
            isRealtimeEnabled: false
        )
        #expect(resolved.terms.isEmpty)
        #expect(resolved.applicableTerms == ["Local", "Global"])
        #expect(resolved.omittedCount == 2)
    }

    @Test func deepgramBatchDoesNotClaimToUseStreamingOnlyVocabulary() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(VocabularyWord(word: "Global"))
        context.insert(
            ScopedVocabularyWord(
                word: "Local",
                scopeKind: .application,
                scopeIdentifier: "com.example.editor"
            )
        )
        try context.save()

        let resolved = TranscriptionVocabularyContext.resolve(
            from: context,
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.example.editor",
                applicationName: "Editor",
                domain: nil
            ),
            model: restrictedModel,
            isRealtimeEnabled: false
        )

        #expect(resolved.terms.isEmpty)
        #expect(resolved.applicableTerms == ["Local", "Global"])
        #expect(resolved.omittedCount == 2)
        #expect(
            !TranscriptionVocabularyCapability.supportsVocabulary(
                for: restrictedModel,
                isRealtimeEnabled: false
            )
        )
    }

    @Test func providersThatDiscardVocabularyAreReportedAsUnsupported() {
        let providers: [ModelProvider] = [.groq, .mistral, .gemini, .xai]

        for provider in providers {
            let model = CloudModel(
                name: "unsupported-test",
                displayName: "Unsupported Test",
                description: "",
                provider: provider,
                speed: 1,
                accuracy: 1,
                isMultilingual: true,
                supportedLanguages: [:]
            )
            #expect(
                !TranscriptionVocabularyCapability.supportsVocabulary(
                    for: model,
                    isRealtimeEnabled: true
                )
            )
            #expect(
                !TranscriptionVocabularyCapability.supportsVocabulary(
                    for: model,
                    isRealtimeEnabled: false
                )
            )
        }
    }

    @Test func dictionaryAllowsSameTermAcrossScopesButRejectsSameScopeDuplicate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appScope = try #require(
            VocabularyScopeSelection(
                kind: .application,
                identifier: "com.example.editor",
                displayName: "Editor"
            )
        )
        let domainScope = try #require(
            VocabularyScopeSelection(kind: .domain, identifier: "example.com")
        )

        #expect(
            DictionaryService.addScopedVocabularyWords(
                "VoiceInk", scope: appScope, existing: [], context: context
            ) == nil
        )
        let existing = try context.fetch(FetchDescriptor<ScopedVocabularyWord>())
        #expect(
            DictionaryService.addScopedVocabularyWords(
                "voiceink", scope: appScope, existing: existing, context: context
            ) != nil
        )
        #expect(
            DictionaryService.addScopedVocabularyWords(
                "VoiceInk", scope: domainScope, existing: existing, context: context
            ) == nil
        )
        #expect(try context.fetch(FetchDescriptor<ScopedVocabularyWord>()).count == 2)
    }

    @Test func requestScopingPreservesResolvedVocabularyForStreamingFallback() {
        let context = TranscriptionRequestContext(
            language: "en",
            prompt: "prompt",
            customVocabulary: ["DomainTerm", "AppTerm", "GlobalTerm"]
        )
        let scoped = context.scoped(to: restrictedModel)
        #expect(scoped.prompt == nil)
        #expect(scoped.customVocabulary == ["DomainTerm", "AppTerm", "GlobalTerm"])
    }

    @Test func backupKeepsScopedWordsSeparateAndLegacyBackupDefaultsToNone() throws {
        let scope = ScopedWordBackup(
            word: "VoiceInk",
            scopeKind: .domain,
            scopeIdentifier: "example.com",
            scopeDisplayName: "Example",
            dateAdded: Date(timeIntervalSince1970: 123)
        )
        let backup = BackupFile(
            version: "1.0.0",
            customPrompts: [],
            modeConfigs: [],
            modeShortcuts: nil,
            vocabularyWords: [WordBackup(word: "Global")],
            scopedVocabularyWords: [scope],
            wordReplacements: nil,
            generalSettings: nil,
            customEmojis: nil,
            customCloudModels: nil
        )
        let decoded = try JSONDecoder().decode(BackupFile.self, from: JSONEncoder().encode(backup))
        #expect(decoded.vocabularyWords?.map(\.word) == ["Global"])
        #expect(decoded.scopedVocabularyWords?.map(\.word) == ["VoiceInk"])

        let legacy = try JSONDecoder().decode(
            BackupFile.self,
            from: Data(#"{"version":"0.9.0","customPrompts":[],"modeConfigs":[]}"#.utf8)
        )
        #expect(legacy.scopedVocabularyWords == nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VocabularyWord.self, ScopedVocabularyWord.self])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private var restrictedModel: CloudModel {
        CloudModel(
            name: "deepgram-test",
            displayName: "Deepgram Test",
            description: "",
            provider: .deepgram,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: [:]
        )
    }

    private var unsupportedModel: NativeAppleModel {
        NativeAppleModel(
            name: "apple-test",
            displayName: "Apple Test",
            description: "",
            isMultilingualModel: true,
            supportedLanguages: [:]
        )
    }
}
