import AppKit
import Foundation
import OSLog
import SwiftData

/// Local-first configuration and dictionary synchronization over append-only
/// iCloud Drive operation files. No CloudKit entitlement or Team ID is used.
@MainActor
final class CloudConfigurationSyncService: ObservableObject {
    static let shared = CloudConfigurationSyncService()

    struct VocabularyItem: Codable, Equatable, Sendable {
        let word: String
        let dateAdded: Date

        init(word: String, dateAdded: Date) {
            self.word = word
            self.dateAdded = dateAdded
        }
    }

    struct ReplacementItem: Codable, Equatable, Sendable {
        let id: UUID
        let originalText: String
        let replacementText: String
        let dateAdded: Date
        let isEnabled: Bool
    }

    /// Legacy v1 content is retained only so existing installations and iCloud
    /// conflict versions can be imported without losing data.
    struct Content: Codable, Equatable, Sendable {
        let preferences: [String: Data]
        let vocabulary: [VocabularyItem]
        let replacements: [ReplacementItem]
    }

    struct Snapshot: Codable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let revision: UUID
        let updatedAt: Date
        let sourceDeviceID: String
        let preferenceUpdatedAt: [String: Date]
        let content: Content

        init(
            schemaVersion: Int,
            revision: UUID,
            updatedAt: Date,
            sourceDeviceID: String,
            preferenceUpdatedAt: [String: Date] = [:],
            content: Content
        ) {
            self.schemaVersion = schemaVersion
            self.revision = revision
            self.updatedAt = updatedAt
            self.sourceDeviceID = sourceDeviceID
            self.preferenceUpdatedAt = preferenceUpdatedAt
            self.content = content
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion, revision, updatedAt, sourceDeviceID, preferenceUpdatedAt, content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            revision = try container.decode(UUID.self, forKey: .revision)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
            preferenceUpdatedAt =
                try container.decodeIfPresent([String: Date].self, forKey: .preferenceUpdatedAt) ?? [:]
            content = try container.decode(Content.self, forKey: .content)
        }
    }

    enum SyncState: Equatable {
        case disabled
        case waitingForICloud
        case syncing
        case synced
        case failed(String)

        var displayText: String {
            switch self {
            case .disabled: return String(localized: "Off")
            case .waitingForICloud: return String(localized: "Waiting for iCloud Drive")
            case .syncing: return String(localized: "Syncing")
            case .synced: return String(localized: "Up to Date")
            case .failed: return String(localized: "Sync Error")
            }
        }
    }

    @Published private(set) var state: SyncState = .waitingForICloud
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var configurationConflictCount = 0
    @Published private(set) var dictionaryConflictCount = 0

    var statusText: String { state.displayText }
    var errorText: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Kept for the existing settings button. The v1 file is read-only after migration.
    var configurationFileURL: URL? {
        syncCore.rootURL
    }

    var isEnabled: Bool {
        defaults.bool(forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
    }

    private static let metadataPrefix = "CloudConfigurationSyncV3."
    private static let configurationMigrationCompletedKey = metadataPrefix + "configurationLegacyMigrationCompleted"
    private static let dictionaryMigrationCompletedKey = metadataPrefix + "dictionaryLegacyMigrationCompleted"
    private static let configurationBootstrapCompletedKey = metadataPrefix + "configurationBootstrapCompleted"
    private static let dictionaryBootstrapCompletedKey = metadataPrefix + "dictionaryBootstrapCompleted"
    private static let reconciliationInterval: TimeInterval = 5 * 60

    private static let structuredPreferenceKeys: Set<String> = [
        "modeConfigurationsV2",
        "customPrompts",
        "customCloudModels",
        "customAIProviders",
    ]

    /// Portable settings are opt-in. Unknown UserDefaults keys stay local.
    private static let portablePreferenceKeys: Set<String> = [
        "AppendTrailingSpace",
        "AppAppearancePreference",
        "EnhancementRetryOnTimeout",
        "EnhancementTimeoutSeconds",
        "IsMenuBarOnly",
        "IsTextFormattingEnabled",
        "IsVADEnabled",
        "MaximumRecordingDurationMinutes",
        "PrewarmModelOnWake",
        "RecorderType",
        "SelectedLanguage",
        "ShortEnhancementWordThreshold",
        "ShowLiveTranscript",
        "SkipShortEnhancement",
        "TrackPostPasteEdits",
        "TranscriptionPrompt",
        "Volcengine ArkSelectedModel",
        "activeConfigurationId",
        "audioResumptionDelay",
        "clipboardRestoreDelay",
        "customProviderModel",
        "isMiddleClickToggleEnabled",
        "isPauseMediaEnabled",
        "isSystemMuteEnabled",
        "localCLICodexModel",
        "localCLICodexReasoningEffort",
        "localCLICommandTemplate",
        "localCLIExecutionMode",
        "localCLISelectedTemplate",
        "localCLITimeoutSeconds",
        "middleClickActivationDelay",
        "pasteMethod",
        "primaryRecordingShortcut",
        "primaryRecordingShortcutMode",
        "restoreClipboardAfterPaste",
        "secondaryRecordingShortcut",
        "secondaryRecordingShortcutMode",
        "selectedAIProvider",
        "selectedStartSoundSelection",
        "selectedStopSoundSelection",
        "useAppleScriptPaste",
        DoubaoSpeechSettings.Keys.enableTwoPassRecognition,
        DoubaoSpeechSettings.Keys.enableTextNormalization,
        DoubaoSpeechSettings.Keys.enablePunctuation,
        DoubaoSpeechSettings.Keys.enableSemanticSmoothing,
        DoubaoSpeechSettings.Keys.enableFirstTextAcceleration,
        DoubaoSpeechSettings.Keys.firstTextAccelerationLevel,
        DoubaoSpeechSettings.Keys.silenceFinalizationMilliseconds,
        DoubaoSpeechSettings.Keys.enablePOIFunctionCall,
        DoubaoSpeechSettings.Keys.enableMusicFunctionCall,
        AliyunQwenSpeechSettings.Keys.region,
        AliyunQwenSpeechSettings.Keys.semanticPunctuationEnabled,
        AliyunQwenSpeechSettings.Keys.maxSentenceSilenceMilliseconds,
        AliyunQwenSpeechSettings.Keys.multiThresholdModeEnabled,
        AliyunQwenSpeechSettings.Keys.heartbeatEnabled,
        AliyunQwenSpeechSettings.Keys.speechNoiseThresholdEnabled,
        AliyunQwenSpeechSettings.Keys.speechNoiseThreshold,
        AliyunQwenSpeechSettings.Keys.useVoiceInkVocabulary,
        AliyunQwenSpeechSettings.Keys.vocabularyWeight,
    ]

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let iCloudDriveRootOverride: URL?
    private let preferencesDomainName: String?
    private let syncCore: ICloudDriveSyncCore
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "CloudConfigurationSyncV3")

    private var modelContext: ModelContext?
    private var lastKnownConfiguration: [String: Data] = [:]
    private var lastKnownDictionary: [String: Data] = [:]
    private var appliedConfigurationOperationIDs: [String: [UUID]] = [:]
    private var appliedDictionaryOperationIDs: [String: [UUID]] = [:]
    private var hasConfigurationBaseline = false
    private var hasDictionaryBaseline = false
    private var isApplyingRemoteState = false
    private var pendingSyncTask: Task<Void, Never>?
    private var timer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private var metadataQueryObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var onRemoteConfigurationApplied: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDriveRootURL: URL? = nil,
        preferencesDomainName: String? = Bundle.main.bundleIdentifier
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDriveRootOverride = iCloudDriveRootURL
        self.preferencesDomainName = preferencesDomainName
        self.syncCore = ICloudDriveSyncCore(
            defaults: defaults,
            fileManager: fileManager,
            iCloudDriveRootURL: iCloudDriveRootURL
        )
    }

    func preparePreferencesForLaunch() {
        guard !shouldSkipAutomaticSyncInTests, isEnabled else {
            state = .disabled
            return
        }
        synchronize(applyDictionary: false, recordLocalChanges: false)
    }

    func start(modelContext: ModelContext, onRemoteConfigurationApplied: @escaping () -> Void) {
        guard !shouldSkipAutomaticSyncInTests else {
            state = .disabled
            return
        }
        self.modelContext = modelContext
        self.onRemoteConfigurationApplied = onRemoteConfigurationApplied
        installObserversIfNeeded()
        if isEnabled {
            startMonitoring()
            synchronize(applyDictionary: true, recordLocalChanges: true)
        } else {
            state = .disabled
        }
    }

    func syncNow() {
        guard isEnabled else { return }
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        synchronize(applyDictionary: modelContext != nil, recordLocalChanges: true)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        guard enabled else {
            stopMonitoring()
            state = .disabled
            return
        }
        startMonitoring()
        synchronize(applyDictionary: modelContext != nil, recordLocalChanges: true)
    }

    func portableContentDidChange() {
        scheduleSync()
    }

    func revealConfigurationFile() {
        guard let configurationFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([configurationFileURL])
    }

    static func isEligiblePreferenceKey(_ key: String) -> Bool {
        portablePreferenceKeys.contains(key)
            || structuredPreferenceKeys.contains(key)
            || (key.hasPrefix("Shortcut_")
                && !key.contains("Migrated"))
            || (key.hasSuffix("SelectedModel")
                && !key.hasPrefix("LocalKeychain_"))
    }

    static func shouldQueueLocalChange(current: Content, lastKnown: Content?, pending: Content?) -> Bool {
        current != lastKnown && current != pending
    }

    private func synchronize(applyDictionary: Bool, recordLocalChanges: Bool) {
        guard isEnabled else {
            state = .disabled
            return
        }
        guard syncCore.rootURL != nil else {
            state = .waitingForICloud
            return
        }

        state = .syncing
        do {
            try migrateLegacyConfigurationIfNeeded()
            if applyDictionary { try migrateLegacyDictionaryIfNeeded() }
            try bootstrapConfigurationIfNeeded()
            if applyDictionary { try bootstrapDictionaryIfNeeded() }
            if !hasConfigurationBaseline { try reconcileConfiguration() }
            if applyDictionary, !hasDictionaryBaseline { try reconcileDictionary() }
            if recordLocalChanges {
                try appendLocalConfigurationChanges()
                if applyDictionary { try appendLocalDictionaryChanges() }
            }
            try reconcileConfiguration()
            if applyDictionary { try reconcileDictionary() }
            lastSyncedAt = Date()
            state = .synced
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reconcileConfiguration() throws {
        let register = try loadRegister(for: .configuration)
        configurationConflictCount = register.conflictCount
        let materialized = register.selectedValues()
        applyConfiguration(materialized)
        lastKnownConfiguration = makeLocalConfiguration()
        appliedConfigurationOperationIDs = activeOperationIDs(in: register)
        hasConfigurationBaseline = true
    }

    private func reconcileDictionary() throws {
        guard let modelContext else { return }
        let register = try loadRegister(for: .dictionary)
        dictionaryConflictCount = register.conflictCount
        let materialized = register.selectedValues(addWins: true)
        try applyDictionary(materialized, context: modelContext)
        lastKnownDictionary = makeLocalDictionary()
        appliedDictionaryOperationIDs = activeOperationIDs(in: register)
        hasDictionaryBaseline = true
    }

    private func appendLocalConfigurationChanges() throws {
        let current = makeLocalConfiguration()
        let mutations = mutations(
            current: current,
            previous: lastKnownConfiguration,
            appliedOperationIDs: appliedConfigurationOperationIDs
        )
        guard !mutations.isEmpty else { return }
        _ = try syncCore.appendChunked(mutations, domain: .configuration)
        lastKnownConfiguration = current
    }

    private func appendLocalDictionaryChanges() throws {
        let current = makeLocalDictionary()
        let mutations = mutations(
            current: current,
            previous: lastKnownDictionary,
            appliedOperationIDs: appliedDictionaryOperationIDs
        )
        guard !mutations.isEmpty else { return }
        _ = try syncCore.appendChunked(mutations, domain: .dictionary)
        lastKnownDictionary = current
    }

    private func mutations(
        current: [String: Data],
        previous: [String: Data],
        appliedOperationIDs: [String: [UUID]]
    ) -> [VoiceInkSyncMutation] {
        Set(current.keys).union(previous.keys).sorted().compactMap { key in
            guard current[key] != previous[key] else { return nil }
            return VoiceInkSyncMutation(
                key: key,
                value: current[key],
                supersededOperationIDs: appliedOperationIDs[key] ?? []
            )
        }
    }

    private func loadRegister(for domain: VoiceInkSyncDomain) throws -> VoiceInkSyncRegisterState {
        var register = VoiceInkSyncRegisterState()
        for envelope in try syncCore.readAll(in: domain) {
            register.apply(envelope, batch: try syncCore.decodeBatch(from: envelope))
        }
        return register
    }

    private func activeOperationIDs(
        in register: VoiceInkSyncRegisterState
    ) -> [String: [UUID]] {
        register.candidatesByKey.reduce(into: [:]) { result, element in
            result[element.key] = register.operationIDs(for: element.key)
        }
    }

    private func makeLocalConfiguration() -> [String: Data] {
        guard let domainName = preferencesDomainName,
            let domain = defaults.persistentDomain(forName: domainName)
        else { return [:] }

        var result: [String: Data] = [:]
        for (key, value) in domain where Self.isEligiblePreferenceKey(key) {
            guard !Self.structuredPreferenceKeys.contains(key) else { continue }
            if let encoded = Self.encodePreferenceValue(value) {
                result["preference/\(key)"] = encoded
            }
        }
        addStructuredEntities(from: domain, to: &result)
        return result
    }

    private func addStructuredEntities(from domain: [String: Any], to result: inout [String: Data]) {
        if let data = domain["modeConfigurationsV2"] as? Data,
            let values = try? JSONDecoder().decode([ModeConfig].self, from: data)
        {
            for value in values { result["entity/mode/\(value.id.uuidString)"] = try? JSONEncoder().encode(value) }
        }
        if let data = domain["customPrompts"] as? Data,
            let values = try? JSONDecoder().decode([CustomPrompt].self, from: data)
        {
            for value in values { result["entity/prompt/\(value.id.uuidString)"] = try? JSONEncoder().encode(value) }
        }
        if let data = domain["customCloudModels"] as? Data,
            let values = try? JSONDecoder().decode([CustomCloudModel].self, from: data)
        {
            for value in values { result["entity/cloud-model/\(value.id.uuidString)"] = try? JSONEncoder().encode(value) }
        }
        if let data = domain["customAIProviders"] as? Data,
            let values = try? JSONDecoder().decode([CustomAIProviderConfig].self, from: data)
        {
            for value in values { result["entity/ai-provider/\(value.id.uuidString)"] = try? JSONEncoder().encode(value) }
        }
    }

    private func applyConfiguration(_ values: [String: Data]) {
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = false }

        let remotePreferenceKeys = Set(values.keys.compactMap { key -> String? in
            guard key.hasPrefix("preference/") else { return nil }
            return String(key.dropFirst("preference/".count))
        })
        if let domainName = preferencesDomainName,
            let existing = defaults.persistentDomain(forName: domainName)
        {
            for key in existing.keys where Self.isEligiblePreferenceKey(key)
                && !Self.structuredPreferenceKeys.contains(key)
                && !remotePreferenceKeys.contains(key)
            {
                defaults.removeObject(forKey: key)
            }
        }

        for (path, data) in values where path.hasPrefix("preference/") {
            let key = String(path.dropFirst("preference/".count))
            guard Self.isEligiblePreferenceKey(key), let value = Self.decodePreferenceValue(data) else { continue }
            defaults.set(value, forKey: key)
        }

        applyEntities(values, prefix: "entity/mode/", key: "modeConfigurationsV2", as: ModeConfig.self)
        applyEntities(values, prefix: "entity/prompt/", key: "customPrompts", as: CustomPrompt.self)
        applyEntities(values, prefix: "entity/cloud-model/", key: "customCloudModels", as: CustomCloudModel.self)
        applyEntities(values, prefix: "entity/ai-provider/", key: "customAIProviders", as: CustomAIProviderConfig.self)

        onRemoteConfigurationApplied?()
        NotificationCenter.default.post(name: .cloudConfigurationDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func applyEntities<T: Codable & Identifiable>(
        _ values: [String: Data],
        prefix: String,
        key: String,
        as type: T.Type
    ) where T.ID: CustomStringConvertible {
        let entities = values
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.key < $1.key }
            .compactMap { try? JSONDecoder().decode(type, from: $0.value) }
        if entities.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(entities) {
            defaults.set(data, forKey: key)
        }
    }

    private func makeLocalDictionary() -> [String: Data] {
        guard let modelContext else { return [:] }
        var result: [String: Data] = [:]
        if let words = try? modelContext.fetch(FetchDescriptor<VocabularyWord>()) {
            for item in words {
                let normalized = Self.normalizedDictionaryText(item.word)
                guard !normalized.isEmpty,
                    let data = try? PropertyListEncoder.voiceInkDictionary.encode(
                        VocabularyItem(word: item.word.trimmingCharacters(in: .whitespacesAndNewlines), dateAdded: item.dateAdded)
                    )
                else { continue }
                result["vocabulary/\(VoiceInkSyncEnvelope.sha256(Data(normalized.utf8)))"] = data
            }
        }
        if let replacements = try? modelContext.fetch(FetchDescriptor<WordReplacement>()) {
            for item in replacements {
                for original in Self.replacementTokens(item.originalText) {
                    let normalized = Self.normalizedDictionaryText(original)
                    guard !normalized.isEmpty else { continue }
                    let value = ReplacementItem(
                        id: item.id,
                        originalText: original,
                        replacementText: item.replacementText,
                        dateAdded: item.dateAdded,
                        isEnabled: item.isEnabled
                    )
                    if let data = try? PropertyListEncoder.voiceInkDictionary.encode(value) {
                        result["replacement/\(VoiceInkSyncEnvelope.sha256(Data(normalized.utf8)))"] = data
                    }
                }
            }
        }
        return result
    }

    private func applyDictionary(_ values: [String: Data], context: ModelContext) throws {
        let remoteVocabulary = values
            .filter { $0.key.hasPrefix("vocabulary/") }
            .compactMap { try? PropertyListDecoder().decode(VocabularyItem.self, from: $0.value) }
        let remoteReplacements = values
            .filter { $0.key.hasPrefix("replacement/") }
            .compactMap { try? PropertyListDecoder().decode(ReplacementItem.self, from: $0.value) }

        let localVocabulary = try context.fetch(FetchDescriptor<VocabularyWord>())
        let localReplacements = try context.fetch(FetchDescriptor<WordReplacement>())
        let localVocabularyMap = Dictionary(
            localVocabulary.map { (Self.normalizedDictionaryText($0.word), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteVocabularyMap = Dictionary(
            remoteVocabulary.map { (Self.normalizedDictionaryText($0.word), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (key, local) in localVocabularyMap where remoteVocabularyMap[key] == nil { context.delete(local) }
        for (key, remote) in remoteVocabularyMap where localVocabularyMap[key] == nil {
            context.insert(VocabularyWord(word: remote.word, dateAdded: remote.dateAdded))
        }

        let localReplacementMap = Dictionary(
            localReplacements.flatMap { item in
                Self.replacementTokens(item.originalText).map { (Self.normalizedDictionaryText($0), item) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteReplacementMap = Dictionary(
            remoteReplacements.map { (Self.normalizedDictionaryText($0.originalText), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for local in localReplacements {
            let keys = Set(Self.replacementTokens(local.originalText).map(Self.normalizedDictionaryText))
            if keys.count != 1 || keys.allSatisfy({ remoteReplacementMap[$0] == nil }) { context.delete(local) }
        }
        for (key, remote) in remoteReplacementMap {
            if let local = localReplacementMap[key], Self.replacementTokens(local.originalText).count == 1 {
                local.originalText = remote.originalText
                local.replacementText = remote.replacementText
                local.isEnabled = remote.isEnabled
            } else {
                let replacement = WordReplacement(
                    originalText: remote.originalText,
                    replacementText: remote.replacementText,
                    dateAdded: remote.dateAdded,
                    isEnabled: remote.isEnabled
                )
                replacement.id = remote.id
                context.insert(replacement)
            }
        }
        try context.save()
        DictionaryService.removeExactDuplicateContent(context: context, source: "iCloud Drive Sync v3")
    }

    private func migrateLegacyConfigurationIfNeeded() throws {
        guard !defaults.bool(forKey: Self.configurationMigrationCompletedKey) else { return }
        let snapshots = try legacySnapshots()
        guard !snapshots.isEmpty else {
            defaults.set(true, forKey: Self.configurationMigrationCompletedKey)
            return
        }

        var configuration: [String: Data] = [:]
        for snapshot in snapshots.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            mergeLegacyPreferences(snapshot.content.preferences, into: &configuration)
        }
        if !configuration.isEmpty {
            try appendMutations(
                configuration.sorted { $0.key < $1.key }.map {
                    VoiceInkSyncMutation(key: $0.key, value: $0.value)
                },
                domain: .configuration
            )
        }
        defaults.set(true, forKey: Self.configurationMigrationCompletedKey)
    }

    private func migrateLegacyDictionaryIfNeeded() throws {
        guard !defaults.bool(forKey: Self.dictionaryMigrationCompletedKey) else { return }
        let snapshots = try legacySnapshots()
        guard !snapshots.isEmpty else {
            defaults.set(true, forKey: Self.dictionaryMigrationCompletedKey)
            return
        }

        var dictionary: [String: Data] = [:]
        for snapshot in snapshots.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            for item in snapshot.content.vocabulary {
                let normalized = Self.normalizedDictionaryText(item.word)
                guard !normalized.isEmpty else { continue }
                dictionary["vocabulary/\(VoiceInkSyncEnvelope.sha256(Data(normalized.utf8)))"] =
                    try? PropertyListEncoder.voiceInkDictionary.encode(item)
            }
            for item in snapshot.content.replacements {
                for original in Self.replacementTokens(item.originalText) {
                    let normalized = Self.normalizedDictionaryText(original)
                    var split = item
                    split = ReplacementItem(
                        id: item.id, originalText: original, replacementText: item.replacementText,
                        dateAdded: item.dateAdded, isEnabled: item.isEnabled)
                    dictionary["replacement/\(VoiceInkSyncEnvelope.sha256(Data(normalized.utf8)))"] =
                        try? PropertyListEncoder.voiceInkDictionary.encode(split)
                }
            }
        }
        if !dictionary.isEmpty {
            try appendMutations(
                dictionary.sorted { $0.key < $1.key }.map {
                    VoiceInkSyncMutation(key: $0.key, value: $0.value)
                },
                domain: .dictionary
            )
        }
        defaults.set(true, forKey: Self.dictionaryMigrationCompletedKey)
    }

    private func bootstrapConfigurationIfNeeded() throws {
        guard !defaults.bool(forKey: Self.configurationBootstrapCompletedKey) else { return }
        let remote = try syncCore.readAll(in: .configuration, mergeIntoLocalFrontier: false)
        let current = makeLocalConfiguration()
        let isEstablishedInstallation = defaults.bool(forKey: "hasCompletedOnboardingV2")
        if remote.isEmpty || (isEstablishedInstallation && !current.isEmpty) {
            try appendBootstrap(current, domain: .configuration)
        }
        defaults.set(true, forKey: Self.configurationBootstrapCompletedKey)
    }

    private func bootstrapDictionaryIfNeeded() throws {
        guard !defaults.bool(forKey: Self.dictionaryBootstrapCompletedKey) else { return }
        let remote = try syncCore.readAll(in: .dictionary, mergeIntoLocalFrontier: false)
        let current = makeLocalDictionary()
        if remote.isEmpty || !current.isEmpty {
            try appendBootstrap(current, domain: .dictionary)
        }
        defaults.set(true, forKey: Self.dictionaryBootstrapCompletedKey)
    }

    private func appendBootstrap(_ values: [String: Data], domain: VoiceInkSyncDomain) throws {
        guard !values.isEmpty else { return }
        try appendMutations(
            values.sorted { $0.key < $1.key }.map {
                VoiceInkSyncMutation(key: $0.key, value: $0.value)
            },
            domain: domain
        )
    }

    private func appendMutations(
        _ mutations: [VoiceInkSyncMutation],
        domain: VoiceInkSyncDomain
    ) throws {
        _ = try syncCore.appendChunked(mutations, domain: domain)
    }

    private func mergeLegacyPreferences(_ preferences: [String: Data], into result: inout [String: Data]) {
        var structuredDomain: [String: Any] = [:]
        for (key, encoded) in preferences where Self.isEligiblePreferenceKey(key) {
            guard let value = Self.decodePreferenceValue(encoded) else { continue }
            if Self.structuredPreferenceKeys.contains(key) {
                structuredDomain[key] = value
            } else if let normalized = Self.encodePreferenceValue(value) {
                result["preference/\(key)"] = normalized
            }
        }
        addStructuredEntities(from: structuredDomain, to: &result)
    }

    private func legacySnapshots() throws -> [Snapshot] {
        guard let root = iCloudDriveRootOverride ?? Self.defaultICloudDriveRoot(fileManager: fileManager) else { return [] }
        let url = root.appendingPathComponent("VoiceInk/Configuration/VoiceInkConfig.plist")
        let candidateURLs = (fileManager.fileExists(atPath: url.path) ? [url] : [])
            + (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map(\.url)
        return try candidateURLs.map { candidate in
            let values = try? candidate.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: candidate)
                throw CocoaError(.fileReadNoSuchFile)
            }
            let data = try coordinatedRead(from: candidate)
            guard let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return snapshot
        }
    }

    private func coordinatedRead(from url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { itemURL in
            result = Result { try Data(contentsOf: itemURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isApplyingRemoteState else { return }
                self.scheduleSync()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .portableConfigurationDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleSync() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.syncNow() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.syncNow() } })
    }

    private func startMonitoring() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            }
            timer?.tolerance = 60
        }
        guard iCloudDriveRootOverride == nil, metadataQuery == nil, let root = syncCore.rootURL else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            metadataQueryObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.scheduleSync() } })
        }
        metadataQuery = query
        query.start()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        metadataQuery?.stop()
        metadataQuery = nil
        for observer in metadataQueryObservers { NotificationCenter.default.removeObserver(observer) }
        metadataQueryObservers.removeAll()
    }

    private func scheduleSync() {
        guard isEnabled, !isApplyingRemoteState else { return }
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.synchronize(applyDictionary: self?.modelContext != nil, recordLocalChanges: true)
        }
    }

    private var shouldSkipAutomaticSyncInTests: Bool {
        iCloudDriveRootOverride == nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func defaultICloudDriveRoot(fileManager: FileManager) -> URL? {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return root
    }

    private static func normalizedDictionaryText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func replacementTokens(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func encodePreferenceValue(_ value: Any) -> Data? {
        let normalized: Any
        if let data = value as? Data,
            let json = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(json),
            let canonical = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        {
            normalized = canonical
        } else {
            normalized = value
        }
        let wrapper = ["value": normalized]
        guard PropertyListSerialization.propertyList(wrapper, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0)
    }

    private static func decodePreferenceValue(_ data: Data) -> Any? {
        guard let wrapper = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return wrapper["value"]
    }
}

extension PropertyListEncoder {
    fileprivate static var voiceInkDictionary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
