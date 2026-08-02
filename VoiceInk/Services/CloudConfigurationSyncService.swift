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
        let content: Content
    }

    enum SyncState: Equatable {
        case waitingForICloud
        case syncing
        case synced
        case failed(String)

        var displayText: String {
            switch self {
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

    private static let metadataPrefix = "CloudConfigurationSync."
    private static let lastLocalChangeKey = metadataPrefix + "lastLocalChange"
    private static let lastAppliedRevisionKey = metadataPrefix + "lastAppliedRevision"
    private static let deviceIDKey = metadataPrefix + "deviceID"

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
        // Local maintenance, migration, framework and macOS UI state.
        CleanupSettingsKeys.lastAutomaticAudioCleanupDate,
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
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var onRemoteConfigurationApplied: (() -> Void)?

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// Applies preferences before services read their initial values. Dictionary
    /// entities are applied later, after SwiftData is available.
    func preparePreferencesForLaunch() {
        guard let snapshot = readSnapshot(), snapshot.schemaVersion <= Snapshot.currentSchemaVersion else {
            return
        }

        let appliedRevision = defaults.string(forKey: Self.lastAppliedRevisionKey)
        let localChange = defaults.object(forKey: Self.lastLocalChangeKey) as? Date
        let shouldApply = appliedRevision != snapshot.revision.uuidString
            && isRemoteSnapshotNewer(snapshot, than: localChange)

        guard shouldApply else {
            lastSeenRevision = snapshot.revision
            lastKnownContent = snapshot.content
            lastSyncedAt = snapshot.updatedAt
            state = .synced
            return
        }

        applyPreferences(snapshot.content.preferences)
        recordAppliedSnapshot(snapshot)
        pendingLaunchSnapshot = snapshot
    }

    func start(modelContext: ModelContext, onRemoteConfigurationApplied: @escaping () -> Void) {
        self.modelContext = modelContext
        self.onRemoteConfigurationApplied = onRemoteConfigurationApplied

        if let pendingLaunchSnapshot {
            applyDictionary(from: pendingLaunchSnapshot.content)
            self.pendingLaunchSnapshot = nil
            onRemoteConfigurationApplied()
        }

        installObserversIfNeeded()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }

        poll()
    }

    func syncNow() {
        poll(forceWriteWhenLocal: true)
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
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return root
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

        for name in [NSApplication.didBecomeActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    Task { @MainActor in
                        if note.name == NSApplication.willTerminateNotification {
                            self?.writeLocalSnapshotIfNeeded(force: true)
                        } else {
                            self?.poll()
                        }
                    }
                })
        }

        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.poll()
                }
            })
    }

    private func handleLocalPreferenceChange() {
        guard !isApplyingRemoteSnapshot, !isWritingMetadata else { return }
        guard let content = makeLocalContent(),
            Self.shouldQueueLocalChange(
                current: content,
                lastKnown: lastKnownContent,
                pending: pendingLocalContent
            )
        else {
            return
        }

        // UserDefaults notifications may be delivered after a metadata write
        // completes. Remember the portable content in memory so those delayed
        // notifications cannot continuously schedule another metadata write.
        pendingLocalContent = content
        pendingLocalChangeAt = Date()
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
            self?.writeLocalSnapshotIfNeeded(force: false)
        }
    }

    private func poll(forceWriteWhenLocal: Bool = false) {
        guard configurationFileURL != nil else {
            state = .waitingForICloud
            return
        }

        if let remote = readSnapshot(), remote.schemaVersion <= Snapshot.currentSchemaVersion {
            let localChange = effectiveLocalChangeDate
            let isUnseenRemote = remote.revision != lastSeenRevision
                && defaults.string(forKey: Self.lastAppliedRevisionKey) != remote.revision.uuidString

            if isUnseenRemote, isRemoteSnapshotNewer(remote, than: localChange) {
                applyRemoteSnapshot(remote)
                return
            }

            lastSeenRevision = remote.revision
            if lastKnownContent == nil {
                lastKnownContent = remote.content
            }
        }

        writeLocalSnapshotIfNeeded(force: forceWriteWhenLocal)
    }

    private func writeLocalSnapshotIfNeeded(force: Bool) {
        guard let url = configurationFileURL, let content = makeLocalContent() else {
            state = .waitingForICloud
            return
        }
        guard force || content != lastKnownContent else {
            pendingLocalContent = nil
            pendingLocalChangeAt = nil
            if state != .synced { state = .synced }
            return
        }

        state = .syncing
        let snapshot = Snapshot(
            schemaVersion: Snapshot.currentSchemaVersion,
            revision: UUID(),
            updatedAt: Date(),
            sourceDeviceID: deviceID,
            content: content
        )

        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)

            lastKnownContent = content
            pendingLocalContent = nil
            pendingLocalChangeAt = nil
            lastSeenRevision = snapshot.revision
            lastSyncedAt = snapshot.updatedAt
            setMetadata(snapshot.updatedAt, forKey: Self.lastLocalChangeKey)
            setMetadata(snapshot.revision.uuidString, forKey: Self.lastAppliedRevisionKey)
            state = .synced
            logger.info("Saved portable configuration to iCloud Drive.")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to write iCloud Drive configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyRemoteSnapshot(_ snapshot: Snapshot) {
        state = .syncing
        applyPreferences(snapshot.content.preferences)
        applyDictionary(from: snapshot.content)
        recordAppliedSnapshot(snapshot)
        onRemoteConfigurationApplied?()

        NotificationCenter.default.post(name: .cloudConfigurationDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        logger.info("Applied portable configuration received through iCloud Drive.")
    }

    private func recordAppliedSnapshot(_ snapshot: Snapshot) {
        lastKnownContent = snapshot.content
        pendingLocalContent = nil
        pendingLocalChangeAt = nil
        lastSeenRevision = snapshot.revision
        lastSyncedAt = snapshot.updatedAt
        setMetadata(snapshot.updatedAt, forKey: Self.lastLocalChangeKey)
        setMetadata(snapshot.revision.uuidString, forKey: Self.lastAppliedRevisionKey)
        state = .synced
    }

    private func applyPreferences(_ preferences: [String: Data]) {
        isApplyingRemoteSnapshot = true
        defer { isApplyingRemoteSnapshot = false }

        if let domainName = Bundle.main.bundleIdentifier,
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

    private func applyDictionary(from content: Content) {
        guard let modelContext else { return }

        do {
            for item in try modelContext.fetch(FetchDescriptor<VocabularyWord>()) {
                modelContext.delete(item)
            }
            for item in try modelContext.fetch(FetchDescriptor<WordReplacement>()) {
                modelContext.delete(item)
            }

            for item in content.vocabulary {
                modelContext.insert(VocabularyWord(word: item.word, dateAdded: item.dateAdded))
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
        } catch {
            modelContext.rollback()
            state = .failed(error.localizedDescription)
            logger.error("Failed to apply synchronized dictionary: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeLocalContent() -> Content? {
        var preferences: [String: Data] = [:]
        if let domainName = Bundle.main.bundleIdentifier,
            let domain = defaults.persistentDomain(forName: domainName)
        {
            for (key, value) in domain where Self.isEligiblePreferenceKey(key) {
                guard PropertyListSerialization.propertyList(["value": value], isValidFor: .binary),
                    let data = try? PropertyListSerialization.data(
                        fromPropertyList: ["value": value], format: .binary, options: 0)
                else { continue }
                preferences[key] = data
            }
        }

        guard let modelContext else {
            return Content(preferences: preferences, vocabulary: [], replacements: [])
        }

        do {
            let vocabulary = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
                .map { VocabularyItem(word: $0.word, dateAdded: $0.dateAdded) }
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

    private func readSnapshot() -> Snapshot? {
        guard let url = configurationFileURL, fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListDecoder().decode(Snapshot.self, from: data)
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to read iCloud Drive configuration: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func isRemoteSnapshotNewer(_ snapshot: Snapshot, than localChange: Date?) -> Bool {
        guard let localChange else { return true }
        return snapshot.updatedAt >= localChange
    }

    private var effectiveLocalChangeDate: Date? {
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
