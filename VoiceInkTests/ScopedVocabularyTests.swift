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
            model: restrictedModel
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
            model: unsupportedModel
        )
        #expect(resolved.terms.isEmpty)
        #expect(resolved.applicableTerms == ["Local", "Global"])
        #expect(resolved.omittedCount == 2)
    }

    @Test func deepgramBatchUsesTheSameResolvedVocabularyAsStreaming() throws {
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
            model: restrictedModel
        )

        #expect(resolved.terms == ["Local", "Global"])
        #expect(resolved.applicableTerms == ["Local", "Global"])
        #expect(resolved.omittedCount == 0)
        #expect(
            TranscriptionVocabularyCapability.supportsVocabulary(for: restrictedModel)
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
            #expect(!TranscriptionVocabularyCapability.supportsVocabulary(for: model))
        }
    }

    @Test func aliyunCapabilityHonorsTheVocabularyToggleAndStreamingLimit() throws {
        let model = CloudModel(
            name: "aliyun-test",
            displayName: "Aliyun Test",
            description: "",
            provider: .aliyunQwen,
            speed: 1,
            accuracy: 1,
            isMultilingual: true,
            supportedLanguages: [:]
        )
        let disabledSettings = aliyunSettings(useVoiceInkVocabulary: false)
        let enabledSettings = aliyunSettings(useVoiceInkVocabulary: true)

        #expect(
            !TranscriptionVocabularyCapability.supportsVocabulary(
                for: model,
                aliyunSettings: disabledSettings
            )
        )
        #expect(
            TranscriptionVocabularyCapability.supportsVocabulary(
                for: model,
                aliyunSettings: enabledSettings
            )
        )
        #expect(
            TranscriptionVocabularyCapability.maximumCount(
                for: model,
                isRealtimeEnabled: true
            ) == 2_000
        )
        #expect(
            TranscriptionVocabularyCapability.maximumCount(
                for: model,
                isRealtimeEnabled: false
            ) == nil
        )

        let container = try makeContainer()
        let context = container.mainContext
        context.insert(VocabularyWord(word: "VoiceInk"))
        try context.save()
        let disabledResolution = TranscriptionVocabularyContext.resolve(
            from: context,
            usageContext: .none,
            model: model,
            isRealtimeEnabled: true,
            aliyunSettings: disabledSettings
        )
        #expect(disabledResolution.terms.isEmpty)
        #expect(disabledResolution.applicableTerms == ["VoiceInk"])
        #expect(disabledResolution.omittedCount == 1)
        #expect(disabledResolution.maximumCount == 0)

        let enabledResolution = TranscriptionVocabularyContext.resolve(
            from: context,
            usageContext: .none,
            model: model,
            isRealtimeEnabled: true,
            aliyunSettings: enabledSettings
        )
        #expect(enabledResolution.terms == ["VoiceInk"])
        #expect(enabledResolution.maximumCount == 2_000)
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

    @Test func applicationModeLookupTreatsBundleIdentifierCasingAsEquivalent() {
        #expect(
            ModeManager.bundleIdentifiersMatch(
                "com.microsoft.VSCode",
                "com.microsoft.vscode"
            )
        )
        #expect(!ModeManager.bundleIdentifiersMatch("com.apple.Notes", "com.apple.mail"))
    }

    @Test func transcriptionPreservesVocabularyUsageContextForRetry() {
        let transcription = Transcription(
            text: "VoiceInk",
            duration: 1,
            vocabularyUsageContext: VocabularyUsageContext(
                bundleIdentifier: "com.microsoft.VSCode",
                applicationName: "Visual Studio Code",
                domain: "https://docs.example.com/error-handling"
            )
        )

        #expect(transcription.vocabularyUsageContext.bundleIdentifier == "com.microsoft.vscode")
        #expect(transcription.vocabularyUsageContext.domain == "docs.example.com")
    }

    @Test func browserURLValidationAcceptsErrorWordsButRejectsErrorMessages() {
        #expect(BrowserURLService.isValidBrowserURL("https://errors.example.com/error-handling"))
        #expect(!BrowserURLService.isValidBrowserURL("execution error: browser denied access"))
    }

    @Test func quickAddDefaultsToTheCurrentApplication() throws {
        let state = DictionaryQuickAddScopeState(
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.example.editor",
                applicationName: "Example Editor",
                domain: nil
            )
        )

        let selected = try #require(state.selectedScope)
        #expect(selected.kind == .application)
        #expect(selected.identifier == "com.example.editor")
        #expect(selected.displayName == "Example Editor")
        #expect(!state.hasUserSelection)
    }

    @Test func quickAddPromotesABrowserTargetToItsDetectedDomain() throws {
        var state = DictionaryQuickAddScopeState(
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                domain: nil
            )
        )

        state.applyDetectedDomain("https://Docs.Example.com/path")

        let selected = try #require(state.selectedScope)
        #expect(selected.kind == .domain)
        #expect(selected.identifier == "docs.example.com")
        #expect(selected.displayName == "docs.example.com")
    }

    @Test func quickAddPrefersAnExistingDomainOverItsApplication() throws {
        let state = DictionaryQuickAddScopeState(
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                domain: "https://docs.example.com/path"
            )
        )

        let selected = try #require(state.selectedScope)
        #expect(selected.kind == .domain)
        #expect(selected.identifier == "docs.example.com")
    }

    @Test func quickAddKeepsTheApplicationWhenWebsiteDetectionFails() throws {
        var state = DictionaryQuickAddScopeState(
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                domain: nil
            )
        )

        state.applyDetectedDomain(nil)

        let selected = try #require(state.selectedScope)
        #expect(selected.kind == .application)
        #expect(selected.identifier == "com.google.chrome")
    }

    @Test func quickAddFallsBackToGlobalWithoutAUsableTarget() {
        let state = DictionaryQuickAddScopeState(usageContext: .none)

        #expect(state.applicationScope == nil)
        #expect(state.domainScope == nil)
        #expect(state.selectedScope == nil)
    }

    @Test func quickAddDoesNotOverrideAManualScopeWhileWebsiteDetectionFinishes() {
        var state = DictionaryQuickAddScopeState(
            usageContext: VocabularyUsageContext(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                domain: nil
            )
        )

        state.select(nil)
        state.applyDetectedDomain("https://docs.example.com/path")

        #expect(state.hasUserSelection)
        #expect(state.domainScope?.identifier == "docs.example.com")
        #expect(state.selectedScope == nil)
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

    private func aliyunSettings(useVoiceInkVocabulary: Bool) -> AliyunQwenSpeechSettings {
        let defaults = AliyunQwenSpeechSettings.defaults
        return AliyunQwenSpeechSettings(
            region: defaults.region,
            apiHost: defaults.apiHost,
            semanticPunctuationEnabled: defaults.semanticPunctuationEnabled,
            maxSentenceSilenceMilliseconds: defaults.maxSentenceSilenceMilliseconds,
            multiThresholdModeEnabled: defaults.multiThresholdModeEnabled,
            heartbeatEnabled: defaults.heartbeatEnabled,
            speechNoiseThresholdEnabled: defaults.speechNoiseThresholdEnabled,
            speechNoiseThreshold: defaults.speechNoiseThreshold,
            useVoiceInkVocabulary: useVoiceInkVocabulary,
            vocabularyWeight: defaults.vocabularyWeight,
            contextPrompt: defaults.contextPrompt,
            useSelectedTextContext: defaults.useSelectedTextContext,
            useClipboardContext: defaults.useClipboardContext,
            useApplicationContext: defaults.useApplicationContext,
            useWindowTitleContext: defaults.useWindowTitleContext,
            keepConnectionReady: defaults.keepConnectionReady
        )
    }
}
