import AppKit
import Foundation
import OSLog
import SwiftData

/// Synchronizes portable VoiceInk configuration through the user's iCloud Drive.
/// This file-based approach works with VoiceInk's ad-hoc signature and needs no Team ID.
@MainActor
final class CloudConfigurationSyncService: ObservableObject {
    static let shared = CloudConfigurationSyncService()

    struct VocabularyItem: Codable, Equatable {
        let word: String
        let dateAdded: Date

        init(word: String, dateAdded: Date) {
            self.word = word
            self.dateAdded = dateAdded
        }
    }

    struct ReplacementItem: Codable, Equatable {
        let id: UUID
        let originalText: String
        let replacementText: String
        let dateAdded: Date
        let isEnabled: Bool
    }

    struct Content: Codable, Equatable {
        let preferences: [String: Data]
        let vocabulary: [VocabularyItem]
        let replacements: [ReplacementItem]
    }

    struct Snapshot: Codable {
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
            case .disabled:
                return String(localized: "Off")
            case .waitingForICloud:
                return String(localized: "Waiting for iCloud Drive")
            case .syncing:
                return String(localized: "Syncing")
            case .synced:
                return String(localized: "Up to Date")
            case .failed:
                return String(localized: "Sync Error")
            }
        }
    }

    @Published private(set) var state: SyncState = .waitingForICloud
    @Published private(set) var lastSyncedAt: Date?

    var statusText: String { state.displayText }
    var errorText: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var configurationFileURL: URL? {
        iCloudDriveRootURL?.appendingPathComponent("VoiceInk/Configuration/VoiceInkConfig.plist")
    }

    var isEnabled: Bool {
        defaults.bool(forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
    }

    private static let metadataPrefix = "CloudConfigurationSync."
    private static let lastLocalChangeKey = metadataPrefix + "lastLocalChange"
    private static let lastAppliedRevisionKey = metadataPrefix + "lastAppliedRevision"
    private static let deviceIDKey = metadataPrefix + "deviceID"
    private static let hasPendingLocalChangeKey = metadataPrefix + "hasPendingLocalChange"
    private static let preferenceUpdatedAtKey = metadataPrefix + "preferenceUpdatedAt"

    private static let excludedExactKeys: Set<String> = [
        // Onboarding and permissions must be completed independently on each Mac.
        "hasCompletedOnboardingV2",
        "hasPreparedOnboardingV2",
        "AccessibilityPermissionRequested",
        "AccessibilityPermissionRegistrationIdentifier",
        "MicrophonePermissionRegistrationIdentifier",
        "ScreenRecordingPermissionRegistrationIdentifier",
        "ScreenRecordingPermissionRequested",
        // Hardware selections are not portable between devices.
        "lastUsedMicrophoneDeviceID",
        "selectedAudioDeviceUID",
        "selectedAudioDeviceModelUID",
        "audioInputMode",
        "prioritizedAudioDevices",
        // A dedicated Alibaba Cloud endpoint contains a workspace identifier,
        // and recognition context may contain private domain information.
        AliyunQwenSpeechSettings.Keys.apiHost,
        AliyunQwenSpeechSettings.Keys.contextPrompt,
        AliyunQwenSpeechSettings.Keys.useSelectedTextContext,
        AliyunQwenSpeechSettings.Keys.useClipboardContext,
        AliyunQwenSpeechSettings.Keys.useApplicationContext,
        AliyunQwenSpeechSettings.Keys.useWindowTitleContext,
        AliyunQwenSpeechSettings.Keys.useScreenContext,
        AliyunQwenSpeechSettings.Keys.keepConnectionReady,
        // A POI hint identifies the user's current or intended city and stays local.
        DoubaoSpeechSettings.Keys.poiCityName,
        DoubaoSpeechSettings.Keys.contextPrompt,
        DoubaoSpeechSettings.Keys.useSelectedTextContext,
        DoubaoSpeechSettings.Keys.useClipboardContext,
        DoubaoSpeechSettings.Keys.useApplicationContext,
        DoubaoSpeechSettings.Keys.useWindowTitleContext,
        DoubaoSpeechSettings.Keys.useScreenContext,
        DoubaoSpeechSettings.Keys.keepConnectionReady,
        // Local maintenance, migration, framework and macOS UI state.
        CleanupSettingsKeys.lastAutomaticAudioCleanupDate,
        CloudSyncSettingsKeys.configurationSyncEnabled,
        CloudSyncSettingsKeys.usageDataSyncEnabled,
        CloudSyncSettingsKeys.usageAudioSyncEnabled,
        "HasCompletedStatsMigration",
        "HasCompletedStatsTokenBackfillV3",
        "streaming-keys-migrated",
        "buffered-local-realtime-migrated-v1",
        "AppleLanguages",
        "AppLanguagePreferenceManagedAppleLanguages",
        "SUHasLaunchedBefore",
        "SULastCheckTime",
        "SUUpdateGroupIdentifier",
        "NSNavPanelExpandedSizeForOpenMode",
        "NSOSPLastRootDirectory",
    ]

    private static let excludedPrefixes = [
        metadataPrefix,
        // Usage synchronization cursors and device identity are local-only.
        // Syncing these values makes different Macs impersonate one another.
        "CloudUsageDataSync.",
        "LocalKeychain_",
        "onboarding",
        "NSWindow Frame ",
        "NSNav",
        "NSOS",
        "CK",
        "CloudKit",
        "logExporter.",
    ]

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let iCloudDriveRootOverride: URL?
    private let preferencesDomainName: String?
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "CloudConfigurationSync")

    private var modelContext: ModelContext?
    private var pendingLaunchSnapshot: Snapshot?
    private var lastKnownContent: Content?
    private var lastSeenRevision: UUID?
    private var pendingLocalContent: Content?
    private var pendingLocalChangeAt: Date?
    private var isApplyingRemoteSnapshot = false
    private var isWritingMetadata = false
    private var pendingWriteTask: Task<Void, Never>?
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
    }

    /// Applies preferences before services read their initial values. Dictionary
    /// entities are applied later, after SwiftData is available.
    func preparePreferencesForLaunch() {
        guard !shouldSkipAutomaticSyncInTests else {
            state = .disabled
            return
        }
        guard isEnabled else {
            state = .disabled
            return
        }
        synchronizeWithRemote(applyDictionaryImmediately: false)
    }

    func start(modelContext: ModelContext, onRemoteConfigurationApplied: @escaping () -> Void) {
        guard !shouldSkipAutomaticSyncInTests else {
            state = .disabled
            return
        }
        self.modelContext = modelContext
        self.onRemoteConfigurationApplied = onRemoteConfigurationApplied

        if let pendingLaunchSnapshot {
            isApplyingRemoteSnapshot = true
            if applyDictionary(from: pendingLaunchSnapshot.content) {
                recordAppliedSnapshot(pendingLaunchSnapshot)
                self.pendingLaunchSnapshot = nil
                onRemoteConfigurationApplied()
            }
            isApplyingRemoteSnapshot = false
        }

        installObserversIfNeeded()
        if isEnabled {
            synchronizeWithRemote(applyDictionaryImmediately: true)
        } else {
            state = .disabled
        }
    }

    /// Pulls once and reconciles any pending offline edit. This method never
    /// creates a revision when local portable content has not changed.
    func syncNow() {
        guard isEnabled else { return }
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        synchronizeWithRemote(applyDictionaryImmediately: true)
    }

    func setEnabled(_ enabled: Bool) {
        if isEnabled != enabled {
            defaults.set(enabled, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        }
        pendingWriteTask?.cancel()
        pendingWriteTask = nil

        guard enabled else {
            state = .disabled
            return
        }
        synchronizeWithRemote(applyDictionaryImmediately: modelContext != nil)
    }

    /// Marks a successful non-UserDefaults edit, such as a vocabulary change,
    /// for one event-driven upload.
    func portableContentDidChange() {
        handleLocalContentChange()
    }

    func revealConfigurationFile() {
        guard let configurationFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([configurationFileURL])
    }

    static func isEligiblePreferenceKey(_ key: String) -> Bool {
        guard !excludedExactKeys.contains(key) else { return false }
        return !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    private var iCloudDriveRootURL: URL? {
        if let iCloudDriveRootOverride { return iCloudDriveRootOverride }
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return root
    }

    private var shouldSkipAutomaticSyncInTests: Bool {
        iCloudDriveRootOverride == nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleLocalPreferenceChange()
                }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .portableConfigurationDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.portableContentDidChange() }
            })
    }

    private func handleLocalPreferenceChange() {
        handleLocalContentChange()
    }

    private func handleLocalContentChange() {
        guard isEnabled, !isApplyingRemoteSnapshot, !isWritingMetadata else { return }
        guard let content = makeLocalContent(),
            Self.shouldQueueLocalChange(current: content, lastKnown: lastKnownContent, pending: pendingLocalContent)
        else { return }

        let baseline = pendingLocalContent ?? lastKnownContent
        pendingLocalContent = content
        let changedAt = Date()
        pendingLocalChangeAt = changedAt
        recordLocalPreferenceChanges(
            Self.changedPreferenceKeys(current: content.preferences, baseline: baseline?.preferences),
            changedAt: changedAt
        )
        setMetadata(changedAt, forKey: Self.lastLocalChangeKey)
        setMetadata(true, forKey: Self.hasPendingLocalChangeKey)
        scheduleWrite()
    }

    static func shouldQueueLocalChange(
        current: Content,
        lastKnown: Content?,
        pending: Content?
    ) -> Bool {
        current != lastKnown && current != pending
    }

    private func scheduleWrite() {
        pendingWriteTask?.cancel()
        pendingWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.synchronizeWithRemote(applyDictionaryImmediately: true)
        }
    }

    private func synchronizeWithRemote(applyDictionaryImmediately: Bool) {
        guard isEnabled else {
            state = .disabled
            return
        }
        guard configurationFileURL != nil else {
            state = .waitingForICloud
            return
        }

        state = .syncing
        switch readNewestSnapshot() {
        case .missing:
            if hasPendingLocalChange, applyDictionaryImmediately {
                writePendingLocalSnapshot()
            } else {
                lastKnownContent = makeLocalContent()
                state = .synced
            }

        case .failed(let message):
            state = .failed(message)

        case .available(let remote, let hasConflicts):
            let normalizedRemote = normalizedSnapshot(remote)
            guard let reconciliation = reconcileRemoteSnapshot(normalizedRemote) else { return }
            var snapshotToApply = reconciliation.snapshot
            var conflictWinner = snapshotToApply
            if hasPendingLocalChange,
                let localChangeAt = effectiveLocalChangeDate,
                localChangeWins(
                    changedAt: localChangeAt,
                    deviceID: deviceID,
                    over: snapshotToApply
                )
            {
                guard applyDictionaryImmediately else {
                    if reconciliation.shouldWrite {
                        snapshotToApply =
                            writeReconciledSnapshot(snapshotToApply, clearPendingLocalChange: false) ?? snapshotToApply
                        conflictWinner = snapshotToApply
                    }
                    lastKnownContent = snapshotToApply.content
                    lastSeenRevision = snapshotToApply.revision
                    lastSyncedAt = snapshotToApply.updatedAt
                    state = .synced
                    return
                }
                if makeLocalContent() == snapshotToApply.content {
                    clearPendingLocalChange()
                    if reconciliation.shouldWrite {
                        snapshotToApply = writeReconciledSnapshot(snapshotToApply) ?? snapshotToApply
                        conflictWinner = snapshotToApply
                    }
                    recordAppliedSnapshot(snapshotToApply)
                } else {
                    lastKnownContent = snapshotToApply.content
                    if let localSnapshot = writePendingLocalSnapshot() {
                        conflictWinner = localSnapshot
                        snapshotToApply = localSnapshot
                    }
                }
            } else {
                let appliedRevision = defaults.string(forKey: Self.lastAppliedRevisionKey)
                let isUnseenRemote = snapshotToApply.revision != lastSeenRevision
                    && appliedRevision != snapshotToApply.revision.uuidString

                if reconciliation.shouldWrite {
                    snapshotToApply = writeReconciledSnapshot(snapshotToApply) ?? snapshotToApply
                    conflictWinner = snapshotToApply
                }

                if isUnseenRemote || makeLocalContent() != snapshotToApply.content {
                    if applyDictionaryImmediately {
                        applyRemoteSnapshot(snapshotToApply)
                    } else {
                        isApplyingRemoteSnapshot = true
                        applyPreferences(snapshotToApply.content.preferences)
                        pendingLaunchSnapshot = snapshotToApply
                        lastKnownContent = snapshotToApply.content
                        lastSeenRevision = snapshotToApply.revision
                        lastSyncedAt = snapshotToApply.updatedAt
                        savePreferenceModificationDates(snapshotToApply.preferenceUpdatedAt)
                        clearPendingLocalChange()
                        state = .synced
                        isApplyingRemoteSnapshot = false
                    }
                } else {
                    recordAppliedSnapshot(snapshotToApply)
                }
            }

            if hasConflicts {
                resolveFileConflicts(keeping: conflictWinner)
            }
        }
    }

    @discardableResult
    private func writePendingLocalSnapshot() -> Snapshot? {
        guard let content = makeLocalContent() else {
            state = .failed(String(localized: "Unable to collect local configuration"))
            return nil
        }
        guard let changedAt = effectiveLocalChangeDate else {
            clearPendingLocalChange()
            state = .synced
            return nil
        }

        let snapshot = Snapshot(
            schemaVersion: Snapshot.currentSchemaVersion,
            revision: UUID(),
            updatedAt: changedAt,
            sourceDeviceID: deviceID,
            preferenceUpdatedAt: preferenceModificationDates(for: content, defaultDate: changedAt),
            content: content
        )

        do {
            try writeSnapshot(snapshot)
            lastKnownContent = content
            lastSeenRevision = snapshot.revision
            lastSyncedAt = snapshot.updatedAt
            savePreferenceModificationDates(snapshot.preferenceUpdatedAt)
            setMetadata(snapshot.revision.uuidString, forKey: Self.lastAppliedRevisionKey)
            clearPendingLocalChange()
            state = .synced
            logger.info("Saved user-modified portable configuration to iCloud Drive.")
            return snapshot
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to write iCloud Drive configuration: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func clearPendingLocalChange() {
        pendingLocalContent = nil
        pendingLocalChangeAt = nil
        setMetadata(false, forKey: Self.hasPendingLocalChangeKey)
    }

    private var hasPendingLocalChange: Bool {
        defaults.bool(forKey: Self.hasPendingLocalChangeKey)
    }

    private func localChangeWins(changedAt: Date, deviceID: String, over remote: Snapshot) -> Bool {
        if changedAt != remote.updatedAt { return changedAt > remote.updatedAt }
        return deviceID > remote.sourceDeviceID
    }

    private func applyRemoteSnapshot(_ snapshot: Snapshot) {
        state = .syncing
        isApplyingRemoteSnapshot = true
        defer { isApplyingRemoteSnapshot = false }
        applyPreferences(snapshot.content.preferences)
        guard applyDictionary(from: snapshot.content) else { return }
        recordAppliedSnapshot(snapshot)
        onRemoteConfigurationApplied?()

        NotificationCenter.default.post(name: .cloudConfigurationDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        logger.info("Applied portable configuration received through iCloud Drive.")
    }

    private func recordAppliedSnapshot(_ snapshot: Snapshot) {
        lastKnownContent = snapshot.content
        clearPendingLocalChange()
        lastSeenRevision = snapshot.revision
        lastSyncedAt = snapshot.updatedAt
        savePreferenceModificationDates(snapshot.preferenceUpdatedAt)
        setMetadata(snapshot.revision.uuidString, forKey: Self.lastAppliedRevisionKey)
        state = .synced
    }

    private func applyPreferences(_ preferences: [String: Data]) {
        if let domainName = preferencesDomainName,
            let existing = defaults.persistentDomain(forName: domainName)
        {
            for key in existing.keys where Self.isEligiblePreferenceKey(key) && preferences[key] == nil {
                defaults.removeObject(forKey: key)
            }
        }

        for (key, encodedValue) in preferences {
            guard Self.isEligiblePreferenceKey(key),
                let wrapper = try? PropertyListSerialization.propertyList(from: encodedValue, format: nil),
                let dictionary = wrapper as? [String: Any],
                let value = dictionary["value"]
            else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private func applyDictionary(from content: Content) -> Bool {
        guard let modelContext else { return false }

        do {
            for item in try modelContext.fetch(FetchDescriptor<VocabularyWord>()) {
                modelContext.delete(item)
            }
            for item in try modelContext.fetch(FetchDescriptor<WordReplacement>()) {
                modelContext.delete(item)
            }

            for item in content.vocabulary {
                modelContext.insert(
                    VocabularyWord(
                        word: item.word,
                        dateAdded: item.dateAdded
                    )
                )
            }
            for item in content.replacements {
                let replacement = WordReplacement(
                    originalText: item.originalText,
                    replacementText: item.replacementText,
                    dateAdded: item.dateAdded,
                    isEnabled: item.isEnabled
                )
                replacement.id = item.id
                modelContext.insert(replacement)
            }
            try modelContext.save()
            DictionaryService.removeExactDuplicateContent(context: modelContext, source: "iCloud sync")
            return true
        } catch {
            modelContext.rollback()
            state = .failed(error.localizedDescription)
            logger.error("Failed to apply synchronized dictionary: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func makeLocalContent() -> Content? {
        var preferences: [String: Data] = [:]
        if let domainName = preferencesDomainName,
            let domain = defaults.persistentDomain(forName: domainName)
        {
            for (key, value) in domain where Self.isEligiblePreferenceKey(key) {
                guard let data = Self.encodePreferenceValue(value) else { continue }
                preferences[key] = data
            }
        }

        guard let modelContext else {
            return Content(preferences: preferences, vocabulary: [], replacements: [])
        }

        do {
            let vocabulary = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
                .map {
                    VocabularyItem(
                        word: $0.word,
                        dateAdded: $0.dateAdded
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.word == rhs.word { return lhs.dateAdded < rhs.dateAdded }
                    return lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
                }
            let replacements = try modelContext.fetch(FetchDescriptor<WordReplacement>())
                .map {
                    ReplacementItem(
                        id: $0.id,
                        originalText: $0.originalText,
                        replacementText: $0.replacementText,
                        dateAdded: $0.dateAdded,
                        isEnabled: $0.isEnabled
                    )
                }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            return Content(preferences: preferences, vocabulary: vocabulary, replacements: replacements)
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to collect local dictionary for synchronization: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private struct SnapshotReconciliation {
        let snapshot: Snapshot
        let shouldWrite: Bool
    }

    private func reconcileRemoteSnapshot(_ remote: Snapshot) -> SnapshotReconciliation? {
        guard let localContent = makeLocalContent() else {
            state = .failed(String(localized: "Unable to collect local configuration"))
            return nil
        }

        let localDates = preferenceModificationDates(
            for: localContent,
            defaultDate: localPreferenceFallbackDate
        )
        let merged = Self.mergePreferencesByModificationDate(
            localPreferences: localContent.preferences,
            localUpdatedAt: localDates,
            localDeviceID: deviceID,
            remotePreferences: remote.content.preferences,
            remoteUpdatedAt: remote.preferenceUpdatedAt,
            remoteSnapshotDate: remote.updatedAt,
            remoteDeviceID: remote.sourceDeviceID
        )
        let mergedContent = Content(
            preferences: merged.preferences,
            vocabulary: remote.content.vocabulary,
            replacements: remote.content.replacements
        )
        let mergedSnapshot = Snapshot(
            schemaVersion: Snapshot.currentSchemaVersion,
            revision: remote.revision,
            updatedAt: remote.updatedAt,
            sourceDeviceID: remote.sourceDeviceID,
            preferenceUpdatedAt: merged.preferenceUpdatedAt,
            content: mergedContent
        )
        let shouldWrite = mergedContent != remote.content
            || merged.preferenceUpdatedAt != remote.preferenceUpdatedAt
            || remote.schemaVersion != Snapshot.currentSchemaVersion
        return SnapshotReconciliation(snapshot: mergedSnapshot, shouldWrite: shouldWrite)
    }

    private var localPreferenceFallbackDate: Date {
        effectiveLocalChangeDate
            ?? defaults.object(forKey: Self.lastLocalChangeKey) as? Date
            ?? .distantPast
    }

    static func changedPreferenceKeys(current: [String: Data], baseline: [String: Data]?) -> Set<String> {
        guard let baseline else {
            return Set(current.keys)
        }
        let keys = Set(current.keys).union(baseline.keys)
        return Set(keys.filter { current[$0] != baseline[$0] })
    }

    private func recordLocalPreferenceChanges(_ keys: Set<String>, changedAt: Date) {
        guard !keys.isEmpty else { return }
        var dates = loadPreferenceModificationDates()
        for key in keys where Self.isEligiblePreferenceKey(key) {
            dates[key] = changedAt
        }
        savePreferenceModificationDates(dates)
    }

    private func preferenceModificationDates(for content: Content, defaultDate: Date) -> [String: Date] {
        var dates = loadPreferenceModificationDates()
        if defaultDate > Date.distantPast {
            for key in content.preferences.keys where dates[key] == nil {
                dates[key] = defaultDate
            }
        }
        return dates.filter { key, _ in
            Self.isEligiblePreferenceKey(key)
        }
    }

    private func loadPreferenceModificationDates() -> [String: Date] {
        guard let data = defaults.data(forKey: Self.preferenceUpdatedAtKey),
            let decoded = try? PropertyListDecoder().decode([String: Date].self, from: data)
        else {
            return [:]
        }
        return decoded.filter { key, _ in
            Self.isEligiblePreferenceKey(key)
        }
    }

    private func savePreferenceModificationDates(_ dates: [String: Date]) {
        let filtered = dates.filter { key, _ in
            Self.isEligiblePreferenceKey(key)
        }
        guard let data = try? PropertyListEncoder().encode(filtered) else { return }
        setMetadata(data, forKey: Self.preferenceUpdatedAtKey)
    }

    private static func mergePreferencesByModificationDate(
        localPreferences: [String: Data],
        localUpdatedAt: [String: Date],
        localDeviceID: String,
        remotePreferences: [String: Data],
        remoteUpdatedAt: [String: Date],
        remoteSnapshotDate: Date,
        remoteDeviceID: String
    ) -> (preferences: [String: Data], preferenceUpdatedAt: [String: Date]) {
        let allKeys = Set(localPreferences.keys)
            .union(remotePreferences.keys)
            .union(localUpdatedAt.keys)
            .union(remoteUpdatedAt.keys)

        var mergedPreferences: [String: Data] = [:]
        var mergedDates: [String: Date] = [:]
        for key in allKeys where isEligiblePreferenceKey(key) {
            let localValue = localPreferences[key]
            let remoteValue = remotePreferences[key]
            let localDate = localUpdatedAt[key]
            let remoteDate = remoteUpdatedAt[key]
                ?? (localDate == nil ? remoteSnapshotDate : .distantPast)

            if localValue == remoteValue {
                if let value = localValue ?? remoteValue {
                    mergedPreferences[key] = value
                }
                let latestDate = max(localDate ?? .distantPast, remoteDate)
                if latestDate > Date.distantPast {
                    mergedDates[key] = latestDate
                }
                continue
            }

            let resolvedLocalDate = localDate ?? .distantPast
            let localWins: Bool
            if resolvedLocalDate != remoteDate {
                localWins = resolvedLocalDate > remoteDate
            } else {
                localWins = localDeviceID > remoteDeviceID
            }

            if localWins {
                if let localValue {
                    mergedPreferences[key] = localValue
                }
                if resolvedLocalDate > Date.distantPast {
                    mergedDates[key] = resolvedLocalDate
                }
            } else {
                if let remoteValue {
                    mergedPreferences[key] = remoteValue
                }
                if remoteDate > Date.distantPast {
                    mergedDates[key] = remoteDate
                }
            }
        }

        return (mergedPreferences, mergedDates)
    }

    @discardableResult
    private func writeReconciledSnapshot(
        _ snapshot: Snapshot,
        clearPendingLocalChange shouldClearPendingLocalChange: Bool = true
    ) -> Snapshot? {
        let latestPreferenceDate = snapshot.preferenceUpdatedAt.values.max() ?? snapshot.updatedAt
        let reconciledSnapshot = Snapshot(
            schemaVersion: Snapshot.currentSchemaVersion,
            revision: UUID(),
            updatedAt: max(snapshot.updatedAt, max(Date(), latestPreferenceDate)),
            sourceDeviceID: deviceID,
            preferenceUpdatedAt: snapshot.preferenceUpdatedAt,
            content: snapshot.content
        )

        do {
            try writeSnapshot(reconciledSnapshot)
            lastKnownContent = reconciledSnapshot.content
            lastSeenRevision = reconciledSnapshot.revision
            lastSyncedAt = reconciledSnapshot.updatedAt
            savePreferenceModificationDates(reconciledSnapshot.preferenceUpdatedAt)
            setMetadata(reconciledSnapshot.revision.uuidString, forKey: Self.lastAppliedRevisionKey)
            if shouldClearPendingLocalChange {
                clearPendingLocalChange()
            }
            state = .synced
            logger.info("Saved reconciled portable configuration to iCloud Drive.")
            return reconciledSnapshot
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to write reconciled iCloud Drive configuration: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private enum SnapshotReadResult {
        case missing
        case available(Snapshot, hasConflicts: Bool)
        case failed(String)
    }

    private func readNewestSnapshot() -> SnapshotReadResult {
        guard let url = configurationFileURL else { return .missing }
        let currentExists = fileManager.fileExists(atPath: url.path)
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        let candidateURLs = (currentExists ? [url] : []) + conflicts.map(\.url)
        guard !candidateURLs.isEmpty else { return .missing }

        var snapshots: [Snapshot] = []
        var errors: [String] = []
        for candidateURL in candidateURLs {
            do {
                let data = try coordinatedRead(from: candidateURL)
                let snapshot = try PropertyListDecoder().decode(Snapshot.self, from: data)
                guard snapshot.schemaVersion <= Snapshot.currentSchemaVersion else {
                    return .failed(String(localized: "A newer VoiceInk version wrote this configuration"))
                }
                snapshots.append(snapshot)
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        guard let newest = snapshots.max(by: Self.snapshotPrecedes) else {
            return .failed(errors.first ?? String(localized: "Unable to read synchronized configuration"))
        }
        return .available(newest, hasConflicts: !conflicts.isEmpty)
    }

    static func snapshotPrecedes(_ lhs: Snapshot, _ rhs: Snapshot) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        if lhs.sourceDeviceID != rhs.sourceDeviceID { return lhs.sourceDeviceID < rhs.sourceDeviceID }
        return lhs.revision.uuidString < rhs.revision.uuidString
    }

    private func normalizedSnapshot(_ snapshot: Snapshot) -> Snapshot {
        Snapshot(
            schemaVersion: snapshot.schemaVersion,
            revision: snapshot.revision,
            updatedAt: snapshot.updatedAt,
            sourceDeviceID: snapshot.sourceDeviceID,
            preferenceUpdatedAt: snapshot.preferenceUpdatedAt.filter { key, _ in
                Self.isEligiblePreferenceKey(key)
            },
            content: Self.normalizedContent(snapshot.content)
        )
    }

    static func normalizedContent(_ content: Content) -> Content {
        var preferences: [String: Data] = [:]
        for (key, encodedValue) in content.preferences {
            guard let wrapper = try? PropertyListSerialization.propertyList(from: encodedValue, format: nil),
                let dictionary = wrapper as? [String: Any],
                let value = dictionary["value"],
                let normalized = encodePreferenceValue(value)
            else { continue }
            preferences[key] = normalized
        }
        return Content(
            preferences: preferences,
            vocabulary: content.vocabulary.sorted {
                if $0.word == $1.word { return $0.dateAdded < $1.dateAdded }
                return $0.word.localizedStandardCompare($1.word) == .orderedAscending
            },
            replacements: content.replacements.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private static func encodePreferenceValue(_ value: Any) -> Data? {
        let normalizedValue: Any
        if let data = value as? Data,
            let json = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(json),
            let canonicalJSON = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        {
            normalizedValue = canonicalJSON
        } else {
            normalizedValue = value
        }

        let wrapper = ["value": normalizedValue]
        guard PropertyListSerialization.propertyList(wrapper, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0)
    }

    private func coordinatedRead(from url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func writeSnapshot(_ snapshot: Snapshot) throws {
        guard let url = configurationFileURL else { throw CocoaError(.fileNoSuchFile) }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) {
            coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func resolveFileConflicts(keeping snapshot: Snapshot) {
        guard let url = configurationFileURL else { return }
        do {
            try writeSnapshot(snapshot)
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                version.isResolved = true
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
            logger.notice("Resolved iCloud configuration file conflicts using the newest user edit.")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to resolve iCloud configuration conflicts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var effectiveLocalChangeDate: Date? {
        guard hasPendingLocalChange else { return nil }
        let persisted = defaults.object(forKey: Self.lastLocalChangeKey) as? Date
        return [persisted, pendingLocalChangeAt].compactMap { $0 }.max()
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: Self.deviceIDKey) { return existing }
        let created = UUID().uuidString
        setMetadata(created, forKey: Self.deviceIDKey)
        return created
    }

    private func setMetadata(_ value: Any, forKey key: String) {
        isWritingMetadata = true
        defaults.set(value, forKey: key)
        isWritingMetadata = false
    }
}
