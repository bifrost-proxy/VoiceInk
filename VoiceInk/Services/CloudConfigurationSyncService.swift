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

    nonisolated var isEnabled: Bool {
        defaults.bool(forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
    }

    nonisolated private static let metadataPrefix = "CloudConfigurationSyncV3."
    nonisolated private static let configurationMigrationCompletedKey = metadataPrefix + "configurationLegacyMigrationCompleted"
    nonisolated private static let dictionaryMigrationCompletedKey = metadataPrefix + "dictionaryLegacyMigrationCompleted"
    nonisolated private static let configurationBootstrapCompletedKey = metadataPrefix + "configurationBootstrapCompleted"
    nonisolated private static let dictionaryBootstrapCompletedKey = metadataPrefix + "dictionaryBootstrapCompleted"
    private static let reconciliationInterval: TimeInterval = 5 * 60

    nonisolated private static let structuredPreferenceKeys: Set<String> = [
        "modeConfigurationsV2",
        "customPrompts",
        "customCloudModels",
        "customAIProviders",
    ]

    /// Portable settings are opt-in. Unknown UserDefaults keys stay local.
    nonisolated private static let portablePreferenceKeys: Set<String> = [
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

    nonisolated(unsafe) private let defaults: UserDefaults
    nonisolated(unsafe) private let fileManager: FileManager
    nonisolated private let iCloudDriveRootOverride: URL?
    nonisolated private let preferencesDomainName: String?
    nonisolated private let syncCore: ICloudDriveSyncCore
    private let executionCoordinator: ICloudSyncExecutionCoordinator
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "CloudConfigurationSyncV3")

    private var modelContainer: ModelContainer?
    // Accessed only by ICloudSyncExecutionCoordinator's serial utility queue.
    nonisolated(unsafe) private var lastKnownConfiguration: [String: Data] = [:]
    nonisolated(unsafe) private var lastKnownDictionary: [String: Data] = [:]
    nonisolated(unsafe) private var appliedConfigurationOperationIDs: [String: [UUID]] = [:]
    nonisolated(unsafe) private var appliedDictionaryOperationIDs: [String: [UUID]] = [:]
    nonisolated(unsafe) private var hasConfigurationBaseline = false
    nonisolated(unsafe) private var hasDictionaryBaseline = false
    nonisolated(unsafe) private var workerConfigurationConflictCount = 0
    nonisolated(unsafe) private var workerDictionaryConflictCount = 0
    private var syncTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var syncIsRunning = false
    private var syncRequestedWhileRunning = false
    private var consecutiveFailureCount = 0
    private var syncGeneration = 0
    private var timer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private var metadataQueryObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var onRemoteConfigurationApplied: (() -> Void)?

    private struct SyncOutcome: Sendable {
        let configurationConflictCount: Int
        let dictionaryConflictCount: Int
    }

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDriveRootURL: URL? = nil,
        preferencesDomainName: String? = Bundle.main.bundleIdentifier,
        executionCoordinator: ICloudSyncExecutionCoordinator = .shared
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDriveRootOverride = iCloudDriveRootURL
        self.preferencesDomainName = preferencesDomainName
        self.executionCoordinator = executionCoordinator
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
        requestSync(applyDictionary: false, recordLocalChanges: false)
    }

    func start(modelContext: ModelContext, onRemoteConfigurationApplied: @escaping () -> Void) {
        guard !shouldSkipAutomaticSyncInTests else {
            state = .disabled
            return
        }
        self.modelContainer = modelContext.container
        self.onRemoteConfigurationApplied = onRemoteConfigurationApplied
        installObserversIfNeeded()
        if isEnabled {
            startMonitoring()
            requestSync(applyDictionary: true, recordLocalChanges: true)
        } else {
            state = .disabled
        }
    }

    func syncNow() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        requestSync(applyDictionary: modelContainer != nil, recordLocalChanges: true)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        syncGeneration += 1
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        guard enabled else {
            stopMonitoring()
            state = .disabled
            return
        }
        startMonitoring()
        consecutiveFailureCount = 0
        requestSync(applyDictionary: modelContainer != nil, recordLocalChanges: true)
    }

    func portableContentDidChange() {
        scheduleSync()
    }

    func revealConfigurationFile() {
        guard let configurationFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([configurationFileURL])
    }

    nonisolated static func isEligiblePreferenceKey(_ key: String) -> Bool {
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

    private func requestSync(applyDictionary: Bool, recordLocalChanges: Bool) {
        guard retryTask == nil else {
            syncRequestedWhileRunning = true
            return
        }
        guard !syncIsRunning else {
            syncRequestedWhileRunning = true
            return
        }
        guard !AudioDeviceManager.shared.isRecordingActive else {
            scheduleRetry(after: 5, applyDictionary: applyDictionary, recordLocalChanges: recordLocalChanges)
            return
        }
        syncIsRunning = true
        state = .syncing
        let modelContainer = self.modelContainer
        let executionCoordinator = self.executionCoordinator
        let generation = syncGeneration
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await executionCoordinator.run { [self] in
                    let context = modelContainer.map(ModelContext.init)
                    return try self.synchronize(
                        modelContext: context,
                        applyDictionary: applyDictionary,
                        recordLocalChanges: recordLocalChanges
                    )
                }
                if generation == self.syncGeneration, self.isEnabled {
                    self.configurationConflictCount = outcome.configurationConflictCount
                    self.dictionaryConflictCount = outcome.dictionaryConflictCount
                    self.lastSyncedAt = Date()
                    self.state = .synced
                    self.consecutiveFailureCount = 0
                    self.onRemoteConfigurationApplied?()
                    NotificationCenter.default.post(name: .cloudConfigurationDidChange, object: nil)
                    NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                }
            } catch is CancellationError {
                if generation == self.syncGeneration, self.isEnabled {
                    self.scheduleRetry(
                        after: 5,
                        applyDictionary: applyDictionary,
                        recordLocalChanges: recordLocalChanges
                    )
                }
            } catch {
                if generation == self.syncGeneration, self.isEnabled {
                    self.consecutiveFailureCount += 1
                    self.state = .failed(error.localizedDescription)
                    self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                    self.scheduleRetry(
                        after: ICloudSyncRetryPolicy.delay(afterFailureCount: self.consecutiveFailureCount),
                        applyDictionary: applyDictionary,
                        recordLocalChanges: recordLocalChanges
                    )
                }
            }
            self.syncTask = nil
            self.syncIsRunning = false
            let runAgain = self.syncRequestedWhileRunning
            self.syncRequestedWhileRunning = false
            if runAgain, self.retryTask == nil {
                self.requestSync(applyDictionary: applyDictionary, recordLocalChanges: recordLocalChanges)
            }
        }
    }

    var isSyncRunningForTesting: Bool { syncIsRunning }

    private func scheduleRetry(
        after delay: TimeInterval,
        applyDictionary: Bool,
        recordLocalChanges: Bool
    ) {
        guard retryTask == nil, isEnabled else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.requestSync(applyDictionary: applyDictionary, recordLocalChanges: recordLocalChanges)
        }
    }

    private nonisolated func synchronize(
        modelContext: ModelContext?,
        applyDictionary: Bool,
        recordLocalChanges: Bool
    ) throws -> SyncOutcome {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard isEnabled else {
            return SyncOutcome(configurationConflictCount: 0, dictionaryConflictCount: 0)
        }
        guard syncCore.rootURL != nil else { throw CocoaError(.fileNoSuchFile) }

        try migrateLegacyConfigurationIfNeeded()
        if applyDictionary { try migrateLegacyDictionaryIfNeeded() }
        try bootstrapConfigurationIfNeeded()
        if applyDictionary { try bootstrapDictionaryIfNeeded(modelContext: modelContext) }
        if !hasConfigurationBaseline { try reconcileConfiguration() }
        if applyDictionary, !hasDictionaryBaseline { try reconcileDictionary(modelContext: modelContext) }
        if recordLocalChanges {
            try appendLocalConfigurationChanges()
            if applyDictionary { try appendLocalDictionaryChanges(modelContext: modelContext) }
        }
        try reconcileConfiguration()
        if applyDictionary { try reconcileDictionary(modelContext: modelContext) }
        return SyncOutcome(
            configurationConflictCount: workerConfigurationConflictCount,
            dictionaryConflictCount: workerDictionaryConflictCount
        )
    }

    private nonisolated func reconcileConfiguration() throws {
        let register = try loadRegister(for: .configuration)
        workerConfigurationConflictCount = register.conflictCount
        let materialized = register.selectedValues()
        applyConfiguration(materialized)
        lastKnownConfiguration = makeLocalConfiguration()
        appliedConfigurationOperationIDs = activeOperationIDs(in: register)
        hasConfigurationBaseline = true
    }

    private nonisolated func reconcileDictionary(modelContext: ModelContext?) throws {
        guard let modelContext else { return }
        let register = try loadRegister(for: .dictionary)
        workerDictionaryConflictCount = register.conflictCount
        let materialized = register.selectedValues(addWins: true)
        try applyDictionary(materialized, context: modelContext)
        lastKnownDictionary = makeLocalDictionary(modelContext: modelContext)
        appliedDictionaryOperationIDs = activeOperationIDs(in: register)
        hasDictionaryBaseline = true
    }

    private nonisolated func appendLocalConfigurationChanges() throws {
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

    private nonisolated func appendLocalDictionaryChanges(modelContext: ModelContext?) throws {
        let current = makeLocalDictionary(modelContext: modelContext)
        let mutations = mutations(
            current: current,
            previous: lastKnownDictionary,
            appliedOperationIDs: appliedDictionaryOperationIDs
        )
        guard !mutations.isEmpty else { return }
        _ = try syncCore.appendChunked(mutations, domain: .dictionary)
        lastKnownDictionary = current
    }

    private nonisolated func mutations(
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

    private nonisolated func loadRegister(for domain: VoiceInkSyncDomain) throws -> VoiceInkSyncRegisterState {
        var register = VoiceInkSyncRegisterState()
        for envelope in try syncCore.readAll(in: domain) {
            register.apply(envelope, batch: try syncCore.decodeBatch(from: envelope))
        }
        return register
    }

    private nonisolated func activeOperationIDs(
        in register: VoiceInkSyncRegisterState
    ) -> [String: [UUID]] {
        register.candidatesByKey.reduce(into: [:]) { result, element in
            result[element.key] = register.operationIDs(for: element.key)
        }
    }

    private nonisolated func makeLocalConfiguration() -> [String: Data] {
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

    private nonisolated func addStructuredEntities(from domain: [String: Any], to result: inout [String: Data]) {
        if let data = domain["modeConfigurationsV2"] as? Data,
            let values = try? JSONDecoder().decode([ModeConfig].self, from: data)
        {
            for value in values { result["entity/mode/\(value.id.uuidString)"] = try? Self.encodeCanonicalJSON(value) }
        }
        if let data = domain["customPrompts"] as? Data,
            let values = try? JSONDecoder().decode([CustomPrompt].self, from: data)
        {
            for value in values { result["entity/prompt/\(value.id.uuidString)"] = try? Self.encodeCanonicalJSON(value) }
        }
        if let data = domain["customCloudModels"] as? Data,
            let values = try? JSONDecoder().decode([CustomCloudModel].self, from: data)
        {
            for value in values { result["entity/cloud-model/\(value.id.uuidString)"] = try? Self.encodeCanonicalJSON(value) }
        }
        if let data = domain["customAIProviders"] as? Data,
            let values = try? JSONDecoder().decode([CustomAIProviderConfig].self, from: data)
        {
            for value in values { result["entity/ai-provider/\(value.id.uuidString)"] = try? Self.encodeCanonicalJSON(value) }
        }
    }

    private nonisolated func applyConfiguration(_ values: [String: Data]) {
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
            if !Self.preferenceValuesEqual(defaults.object(forKey: key), value) {
                defaults.set(value, forKey: key)
            }
        }

        applyEntities(values, prefix: "entity/mode/", key: "modeConfigurationsV2", as: ModeConfig.self)
        applyEntities(values, prefix: "entity/prompt/", key: "customPrompts", as: CustomPrompt.self)
        applyEntities(values, prefix: "entity/cloud-model/", key: "customCloudModels", as: CustomCloudModel.self)
        applyEntities(values, prefix: "entity/ai-provider/", key: "customAIProviders", as: CustomAIProviderConfig.self)

    }

    private nonisolated func applyEntities<T: Codable & Identifiable>(
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
        } else if let data = try? Self.encodeCanonicalJSON(entities), defaults.data(forKey: key) != data {
            defaults.set(data, forKey: key)
        }
    }

    private nonisolated func makeLocalDictionary(modelContext: ModelContext?) -> [String: Data] {
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

    private nonisolated func applyDictionary(_ values: [String: Data], context: ModelContext) throws {
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
        _ = DictionaryService.removeExactDuplicateContent(context: context, source: "iCloud Drive Sync v3")
    }

    private nonisolated func migrateLegacyConfigurationIfNeeded() throws {
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

    private nonisolated func migrateLegacyDictionaryIfNeeded() throws {
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

    private nonisolated func bootstrapConfigurationIfNeeded() throws {
        guard !defaults.bool(forKey: Self.configurationBootstrapCompletedKey) else { return }
        let remote = try syncCore.readAll(in: .configuration, mergeIntoLocalFrontier: false)
        let current = makeLocalConfiguration()
        let isEstablishedInstallation = defaults.bool(forKey: "hasCompletedOnboardingV2")
        if remote.isEmpty || (isEstablishedInstallation && !current.isEmpty) {
            try appendBootstrap(current, domain: .configuration)
        }
        defaults.set(true, forKey: Self.configurationBootstrapCompletedKey)
    }

    private nonisolated func bootstrapDictionaryIfNeeded(modelContext: ModelContext?) throws {
        guard !defaults.bool(forKey: Self.dictionaryBootstrapCompletedKey) else { return }
        let remote = try syncCore.readAll(in: .dictionary, mergeIntoLocalFrontier: false)
        let current = makeLocalDictionary(modelContext: modelContext)
        if remote.isEmpty || !current.isEmpty {
            try appendBootstrap(current, domain: .dictionary)
        }
        defaults.set(true, forKey: Self.dictionaryBootstrapCompletedKey)
    }

    private nonisolated func appendBootstrap(_ values: [String: Data], domain: VoiceInkSyncDomain) throws {
        guard !values.isEmpty else { return }
        try appendMutations(
            values.sorted { $0.key < $1.key }.map {
                VoiceInkSyncMutation(key: $0.key, value: $0.value)
            },
            domain: domain
        )
    }

    private nonisolated func appendMutations(
        _ mutations: [VoiceInkSyncMutation],
        domain: VoiceInkSyncDomain
    ) throws {
        _ = try syncCore.appendChunked(mutations, domain: domain)
    }

    private nonisolated func mergeLegacyPreferences(_ preferences: [String: Data], into result: inout [String: Data]) {
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

    private nonisolated func legacySnapshots() throws -> [Snapshot] {
        guard let root = iCloudDriveRootOverride ?? Self.defaultICloudDriveRoot(fileManager: fileManager) else { return [] }
        let url = root.appendingPathComponent("VoiceInk/Configuration/VoiceInkConfig.plist")
        let candidateURLs = (fileManager.fileExists(atPath: url.path) ? [url] : [])
            + (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map(\.url)
        var snapshots: [Snapshot] = []
        var hasPendingDownload = false
        for candidate in candidateURLs {
            let values = try? candidate.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: candidate)
                hasPendingDownload = true
                continue
            }
            let data = try coordinatedRead(from: candidate)
            guard let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            snapshots.append(snapshot)
        }
        if hasPendingDownload { throw CocoaError(.fileReadNoSuchFile) }
        return snapshots
    }

    private nonisolated func coordinatedRead(from url: URL) throws -> Data {
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
                guard let self else { return }
                self.scheduleSync()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .portableConfigurationDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleSync() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleSync() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleSync() } })
    }

    private func startMonitoring() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync() }
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
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.debounceTask = nil
            self.requestSync(applyDictionary: self.modelContainer != nil, recordLocalChanges: true)
        }
    }

    private var shouldSkipAutomaticSyncInTests: Bool {
        iCloudDriveRootOverride == nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated private static func defaultICloudDriveRoot(fileManager: FileManager) -> URL? {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return root
    }

    nonisolated private static func normalizedDictionaryText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    nonisolated private static func replacementTokens(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func encodePreferenceValue(_ value: Any) -> Data? {
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

    nonisolated private static func decodePreferenceValue(_ data: Data) -> Any? {
        guard let wrapper = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return wrapper["value"]
    }

    nonisolated private static func encodeCanonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    nonisolated private static func preferenceValuesEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else { return false }
        return encodePreferenceValue(lhs) == encodePreferenceValue(rhs)
    }
}

extension PropertyListEncoder {
    fileprivate static var voiceInkDictionary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
