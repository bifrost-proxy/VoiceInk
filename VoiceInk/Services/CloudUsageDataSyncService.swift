import AppKit
import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Opt-in, local-first usage synchronization over immutable iCloud Drive
/// operations. SwiftData stores never leave the Mac. Transcriptions and every
/// metric are merged independently; audio is stored as verified,
/// content-addressed blobs.
@MainActor
final class CloudUsageDataSyncService: ObservableObject {
    static let shared = CloudUsageDataSyncService()

    struct AudioDescriptor: Codable, Equatable, Hashable, Sendable {
        let sha256: String
        let byteCount: Int64
        let fileExtension: String

        var isValid: Bool {
            sha256.count == 64
                && sha256.unicodeScalars.allSatisfy { scalar in
                    (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                }
                && byteCount >= 0
                && (1...10).contains(fileExtension.count)
                && fileExtension.unicodeScalars.allSatisfy { scalar in
                    (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
                }
        }
    }

    struct TranscriptionPayload: Codable, Equatable, Sendable {
        let id: UUID
        let text: String
        let enhancedText: String?
        let timestamp: Date
        let duration: TimeInterval
        let transcriptionModelName: String?
        let aiEnhancementModelName: String?
        let promptName: String?
        let transcriptionDuration: TimeInterval?
        let enhancementDuration: TimeInterval?
        let modeName: String?
        let modeEmoji: String?
        let transcriptionStatus: String?
        let performanceData: Data?
    }

    struct MetricPayload: Codable, Equatable, Sendable {
        let id: UUID
        let transcriptionId: UUID
        let timestamp: Date
        let source: String?
        let wordCount: Int
        let audioDuration: TimeInterval
        let transcriptionModelName: String?
        let transcriptionDuration: TimeInterval?
        let speedFactor: Double?
        let modeName: String?
        let aiEnhancementModelName: String?
        let enhancementDuration: TimeInterval?
        let enhancementEstimatedTokenCount: Int?
        let performanceData: Data?
    }

    /// Retained exclusively for one-time UsageData/v1 migration.
    struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let revisionID: UUID
        let sourceDeviceID: String
        let sourceDeviceName: String?
        let updatedAt: Date
        let transcription: TranscriptionPayload
        let metric: MetricPayload?
        let audio: AudioDescriptor?
    }

    /// Retained so old manifests remain decodable during migration.
    struct DeviceManifest: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 2

        struct Entry: Codable, Equatable, Sendable {
            let transcriptionID: UUID
            let revisionID: UUID
            let updatedAt: Date
        }

        let schemaVersion: Int
        let sourceDeviceID: String
        let sourceDeviceName: String?
        let updatedAt: Date
        var entries: [UUID: Entry]
    }

    struct TranscriptionValue: Codable, Equatable, Sendable {
        let transcription: TranscriptionPayload
        let audio: AudioDescriptor?
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

    @Published private(set) var state: SyncState = .disabled
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var synchronizedRecordCount = 0
    @Published private(set) var conflictCount = 0
    @Published private(set) var locallySuppressedRecordCount = 0
    @Published private(set) var lastExportCandidateCount = 0
    @Published private(set) var lastImportCandidateCount = 0
    @Published private(set) var lastSyncUsedLegacyScan = false
    @Published private(set) var localDeviceName: String
    @Published private(set) var lastRemoteDeviceName: String?
    @Published private(set) var cloudAudioRecordIDs: Set<UUID> = []

    var statusText: String { state.displayText }
    var errorText: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    var usageDataDirectoryURL: URL? { syncCore.rootURL }

    nonisolated private static let metadataPrefix = "CloudUsageDataSyncV3."
    nonisolated private static let pendingRecordIDsKey = metadataPrefix + "pendingRecordIDs"
    nonisolated private static let pendingGlobalDeletionIDsKey = metadataPrefix + "pendingGlobalDeletionIDs"
    nonisolated private static let locallySuppressedRecordIDsKey = metadataPrefix + "locallySuppressedRecordIDs"
    nonisolated private static let appliedOperationIDsKey = metadataPrefix + "appliedOperationIDs"
    nonisolated private static let localBootstrapCompletedKey = metadataPrefix + "localBootstrapCompleted"
    nonisolated private static let legacyMigrationCompletedKey = metadataPrefix + "legacyMigrationCompleted"
    nonisolated private static let legacyMigratedPathsKey = metadataPrefix + "legacyMigratedPaths"
    nonisolated private static let pendingAudioRecordIDsKey = metadataPrefix + "pendingAudioRecordIDsBySHA"
    nonisolated private static let lastFullMaterializationKey = metadataPrefix + "lastFullMaterializationAt"
    nonisolated private static let reconciliationInterval: TimeInterval = 30 * 60
    nonisolated private static let fullMaterializationInterval: TimeInterval = 24 * 60 * 60

    nonisolated(unsafe) private let defaults: UserDefaults
    nonisolated(unsafe) private let fileManager: FileManager
    nonisolated private let iCloudDriveRootOverride: URL?
    nonisolated private let localRecordingsDirectoryOverride: URL?
    nonisolated private let syncCore: ICloudDriveSyncCore
    private let executionCoordinator: ICloudSyncExecutionCoordinator
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CloudUsageDataSyncV3")

    private var modelContainer: ModelContainer?
    // Accessed only by ICloudSyncExecutionCoordinator's serial utility queue.
    nonisolated(unsafe) private var appliedOperationIDs: [String: [UUID]] = [:]
    nonisolated(unsafe) private var pendingAudioRecordIDsBySHA: [String: Set<UUID>] = [:]
    nonisolated(unsafe) private var audioVerificationCache: [String: VerifiedAudioFile] = [:]
    nonisolated(unsafe) private var audioVerificationCacheIsDirty = false
    nonisolated(unsafe) private(set) var audioHashCountForTesting = 0
    private var timer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private var metadataQueryObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var syncTask: Task<Void, Never>?
    private var eventSyncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var syncRequestedWhileRunning = false
    private var requestedFullScanWhileRunning = false
    private var requestedRepairWhileRunning = false
    private var requestedOperationURLsWhileRunning = Set<URL>()
    private var requestedRecordIDsWhileRunning = Set<UUID>()
    private var scheduledFullScan = false
    private var scheduledOperationURLs = Set<URL>()
    private var scheduledRecordIDs = Set<UUID>()
    private var recordIDsQueuedDuringSync: Set<UUID> = []
    private var deletionIDsQueuedDuringSync: Set<UUID> = []
    private var enqueueAllBeforeNextSync = false
    private var consecutiveFailureCount = 0
    private var syncGeneration = 0
    private struct SyncOutcome: Sendable {
        let processedRecordIDs: Set<UUID>
        let processedDeletionIDs: Set<UUID>
        let synchronizedRecordCount: Int
        let conflictCount: Int
        let exportCandidateCount: Int
        let importCandidateCount: Int
        let usedLegacyScan: Bool
        let didChangeLocalStore: Bool
        let cloudAudioRecordIDs: Set<UUID>
        let latestRemoteDeviceName: String?
    }

    private typealias AppendedBatch = (
        envelope: VoiceInkSyncEnvelope,
        mutations: [VoiceInkSyncMutation]
    )

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDriveRootURL: URL? = nil,
        deviceName: String? = nil,
        localRecordingsDirectoryURL: URL? = nil,
        executionCoordinator: ICloudSyncExecutionCoordinator = .shared
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDriveRootOverride = iCloudDriveRootURL
        self.localRecordingsDirectoryOverride = localRecordingsDirectoryURL
        self.executionCoordinator = executionCoordinator
        let resolvedDeviceName = Self.normalizedDeviceName(deviceName ?? Self.currentDeviceName())
        self.localDeviceName = resolvedDeviceName
        self.syncCore = ICloudDriveSyncCore(
            defaults: defaults,
            fileManager: fileManager,
            iCloudDriveRootURL: iCloudDriveRootURL,
            deviceName: resolvedDeviceName
        )
        self.audioVerificationCache = loadAudioVerificationCache()
        self.appliedOperationIDs = Self.decodeOperationIDs(defaults.data(forKey: Self.appliedOperationIDsKey))
        self.pendingAudioRecordIDsBySHA = Self.decodePendingAudioRecordIDs(
            defaults.data(forKey: Self.pendingAudioRecordIDsKey))
        self.cloudAudioRecordIDs = Set(pendingAudioRecordIDsBySHA.values.flatMap { $0 })
        self.locallySuppressedRecordCount = Set(
            (defaults.stringArray(forKey: Self.locallySuppressedRecordIDsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        ).count
    }

    func start(modelContext: ModelContext) {
        guard !shouldSkipAutomaticSyncInTests else {
            state = .disabled
            return
        }
        self.modelContainer = modelContext.container
        installObserversIfNeeded()
        setEnabled(defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled))
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        syncGeneration += 1
        timer?.invalidate()
        timer = nil
        stopMetadataQuery()
        eventSyncTask?.cancel()
        eventSyncTask = nil
        retryTask?.cancel()
        retryTask = nil
        syncRequestedWhileRunning = false
        requestedFullScanWhileRunning = false
        requestedRepairWhileRunning = false
        requestedOperationURLsWhileRunning.removeAll()
        requestedRecordIDsWhileRunning.removeAll()
        scheduledFullScan = false
        scheduledOperationURLs.removeAll()
        scheduledRecordIDs.removeAll()

        guard enabled else {
            cloudAudioRecordIDs.removeAll()
            state = .disabled
            return
        }

        enqueueAllBeforeNextSync = !defaults.bool(forKey: Self.localBootstrapCompletedKey)
        timer = Timer.scheduledTimer(withTimeInterval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow(fullScan: true, repairLocalStore: false) }
        }
        timer?.tolerance = 5 * 60
        startMetadataQueryIfAvailable()
        syncNow(fullScan: true, repairLocalStore: false)
    }

    func setAudioEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        if defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) {
            if enabled {
                enqueueAllBeforeNextSync = true
                syncNow(fullScan: true, repairLocalStore: true)
            } else {
                pendingAudioRecordIDsBySHA.removeAll()
                cloudAudioRecordIDs.removeAll()
                defaults.removeObject(forKey: Self.pendingAudioRecordIDsKey)
                syncNow(fullScan: true, repairLocalStore: false)
            }
        }
    }

    func hasCloudAudio(for transcriptionID: UUID) -> Bool {
        defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
            && defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
            && cloudAudioRecordIDs.contains(transcriptionID)
    }

    /// Downloads and verifies one source-audio blob in direct response to a user action.
    /// Metadata reconciliation never calls this method.
    func materializeAudioOnDemand(for transcriptionID: UUID) async throws -> URL {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled),
            defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        else {
            throw CocoaError(.userCancelled)
        }
        let executionCoordinator = self.executionCoordinator
        for attempt in 0..<120 {
            guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled),
                defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
            else {
                throw CocoaError(.userCancelled)
            }
            let result = try await executionCoordinator.run { [self] in
                guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled),
                    defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
                else {
                    throw CocoaError(.userCancelled)
                }
                guard let descriptor = try audioDescriptor(for: transcriptionID) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try materializeAudio(descriptor, transcriptionID: transcriptionID)
            }
            if case .available(let url) = result { return url }
            guard attempt < 119 else { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func syncNow(
        fullScan: Bool = true,
        operationURLs: Set<URL> = [],
        forcedRecordIDs: Set<UUID> = [],
        repairLocalStore: Bool = true
    ) {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) else { return }
        guard retryTask == nil else {
            syncRequestedWhileRunning = true
            requestedFullScanWhileRunning = requestedFullScanWhileRunning || fullScan
            requestedRepairWhileRunning = requestedRepairWhileRunning || repairLocalStore
            requestedOperationURLsWhileRunning.formUnion(operationURLs)
            requestedRecordIDsWhileRunning.formUnion(forcedRecordIDs)
            return
        }
        guard syncTask == nil else {
            syncRequestedWhileRunning = true
            requestedFullScanWhileRunning = requestedFullScanWhileRunning || fullScan
            requestedRepairWhileRunning = requestedRepairWhileRunning || repairLocalStore
            requestedOperationURLsWhileRunning.formUnion(operationURLs)
            requestedRecordIDsWhileRunning.formUnion(forcedRecordIDs)
            return
        }
        guard !AudioDeviceManager.shared.isRecordingActive else {
            scheduleRetry(after: 5)
            return
        }
        guard let modelContainer, syncCore.rootURL != nil else {
            state = .waitingForICloud
            consecutiveFailureCount += 1
            scheduleRetry(after: ICloudSyncRetryPolicy.delay(afterFailureCount: consecutiveFailureCount))
            return
        }
        state = .syncing
        let shouldEnqueueAll = enqueueAllBeforeNextSync
        enqueueAllBeforeNextSync = false
        let executionCoordinator = self.executionCoordinator
        let generation = syncGeneration
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await executionCoordinator.run { [self] in
                    try self.performSync(
                        modelContainer: modelContainer,
                        enqueueAll: shouldEnqueueAll,
                        fullScan: fullScan,
                        operationURLs: operationURLs,
                        forcedRecordIDs: forcedRecordIDs,
                        repairLocalStore: repairLocalStore
                    )
                }
                if generation == self.syncGeneration,
                    self.defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
                {
                    var remaining = self.loadIDs(forKey: Self.pendingRecordIDsKey)
                    remaining.subtract(outcome.processedRecordIDs)
                    remaining.formUnion(self.recordIDsQueuedDuringSync)
                    self.recordIDsQueuedDuringSync.removeAll()
                    self.persistIDs(remaining, forKey: Self.pendingRecordIDsKey)

                    var remainingDeletions = self.loadIDs(forKey: Self.pendingGlobalDeletionIDsKey)
                    remainingDeletions.subtract(outcome.processedDeletionIDs)
                    remainingDeletions.formUnion(self.deletionIDsQueuedDuringSync)
                    self.deletionIDsQueuedDuringSync.removeAll()
                    self.persistIDs(remainingDeletions, forKey: Self.pendingGlobalDeletionIDsKey)
                    self.defaults.set(true, forKey: Self.localBootstrapCompletedKey)

                    self.synchronizedRecordCount = outcome.synchronizedRecordCount
                    self.conflictCount = outcome.conflictCount
                    self.lastExportCandidateCount = outcome.exportCandidateCount
                    self.lastImportCandidateCount = outcome.importCandidateCount
                    self.lastSyncUsedLegacyScan = outcome.usedLegacyScan
                    self.cloudAudioRecordIDs = outcome.cloudAudioRecordIDs
                    if let deviceName = outcome.latestRemoteDeviceName {
                        self.lastRemoteDeviceName = deviceName
                    }
                    self.lastSyncedAt = Date()
                    self.state = .synced
                    self.consecutiveFailureCount = 0
                    if outcome.didChangeLocalStore {
                        DashboardStatsCache.shared.markStale()
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: nil)
                        NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                    }
                    self.logger.notice(
                        "Usage sync completed imports=\(outcome.importCandidateCount, privacy: .public) records=\(outcome.synchronizedRecordCount, privacy: .public) conflicts=\(outcome.conflictCount, privacy: .public)"
                    )
                } else {
                    self.enqueueAllBeforeNextSync = self.enqueueAllBeforeNextSync || shouldEnqueueAll
                }
            } catch is CancellationError {
                self.enqueueAllBeforeNextSync = self.enqueueAllBeforeNextSync || shouldEnqueueAll
            } catch {
                self.enqueueAllBeforeNextSync = self.enqueueAllBeforeNextSync || shouldEnqueueAll
                if generation == self.syncGeneration,
                    self.defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
                {
                    self.consecutiveFailureCount += 1
                    if Self.isPendingICloudDownload(error) {
                        self.state = .waitingForICloud
                        self.logger.notice(
                            "Usage sync waiting for iCloud: \(error.localizedDescription, privacy: .public)")
                    } else {
                        self.state = .failed(error.localizedDescription)
                        self.logger.error("Usage sync failed: \(error.localizedDescription, privacy: .public)")
                    }
                    self.scheduleRetry(
                        after: ICloudSyncRetryPolicy.delay(afterFailureCount: self.consecutiveFailureCount)
                    )
                }
            }
            self.syncTask = nil
            let shouldRunAgain = self.syncRequestedWhileRunning
            self.syncRequestedWhileRunning = false
            if (shouldRunAgain || generation != self.syncGeneration), self.retryTask == nil {
                let nextFullScan = self.requestedFullScanWhileRunning
                let nextRepair = self.requestedRepairWhileRunning
                let nextOperationURLs = self.requestedOperationURLsWhileRunning
                let nextRecordIDs = self.requestedRecordIDsWhileRunning
                self.requestedFullScanWhileRunning = false
                self.requestedRepairWhileRunning = false
                self.requestedOperationURLsWhileRunning.removeAll()
                self.requestedRecordIDsWhileRunning.removeAll()
                self.syncNow(
                    fullScan: nextFullScan,
                    operationURLs: nextOperationURLs,
                    forcedRecordIDs: nextRecordIDs,
                    repairLocalStore: nextRepair
                )
            }
        }
    }

    func recordDidChange(_ transcriptionID: UUID) {
        var suppressed = loadIDs(forKey: Self.locallySuppressedRecordIDsKey)
        if suppressed.remove(transcriptionID) != nil {
            persistIDs(suppressed, forKey: Self.locallySuppressedRecordIDsKey)
            locallySuppressedRecordCount = suppressed.count
        }
        enqueueLocalRecords([transcriptionID])
    }

    /// A user-visible delete is global. The durable tombstone is queued before
    /// the SwiftData row is removed, so it survives an app crash or offline Mac.
    func deleteRecordsGlobally(_ transcriptionIDs: Set<UUID>) {
        guard !transcriptionIDs.isEmpty else { return }
        var pending = loadIDs(forKey: Self.pendingGlobalDeletionIDsKey)
        pending.formUnion(transcriptionIDs)
        persistIDs(pending, forKey: Self.pendingGlobalDeletionIDsKey)
        if syncTask != nil { deletionIDsQueuedDuringSync.formUnion(transcriptionIDs) }
        var edits = loadIDs(forKey: Self.pendingRecordIDsKey)
        edits.subtract(transcriptionIDs)
        persistIDs(edits, forKey: Self.pendingRecordIDsKey)
        scheduleEventDrivenSync()
    }

    /// Capacity and automatic retention are local policy. Suppression prevents
    /// an immediate re-download without deleting any other Mac's cloud archive.
    func recordsWereRemovedLocally(_ transcriptionIDs: Set<UUID>) {
        guard !transcriptionIDs.isEmpty else { return }
        var suppressed = loadIDs(forKey: Self.locallySuppressedRecordIDsKey)
        suppressed.formUnion(transcriptionIDs)
        persistIDs(suppressed, forKey: Self.locallySuppressedRecordIDsKey)
        locallySuppressedRecordCount = suppressed.count
        var edits = loadIDs(forKey: Self.pendingRecordIDsKey)
        edits.subtract(transcriptionIDs)
        persistIDs(edits, forKey: Self.pendingRecordIDsKey)
    }

    func restoreLocallySuppressedRecords() {
        persistIDs([], forKey: Self.locallySuppressedRecordIDsKey)
        locallySuppressedRecordCount = 0
        syncNow()
    }

    func revealUsageData() {
        guard let usageDataDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([usageDataDirectoryURL])
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.transcriptionCreated, .transcriptionCompleted] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    if let transcription = notification.object as? Transcription {
                        self?.recordDidChange(transcription.id)
                    } else if let id = notification.object as? UUID {
                        self?.recordDidChange(id)
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .sessionMetricsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                if let id = notification.object as? UUID {
                    self?.recordDidChange(id)
                } else if let ids = notification.object as? [UUID] {
                    self?.enqueueLocalRecords(Set(ids))
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleCatchUpSyncIfDue() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleCatchUpSyncIfDue() } })
    }

    private func scheduleCatchUpSyncIfDue(now: Date = Date()) {
        guard Self.shouldRunCatchUpSync(lastSyncedAt: lastSyncedAt, now: now) else { return }
        scheduleEventDrivenSync(fullScan: true)
    }

    nonisolated static func shouldRunCatchUpSync(lastSyncedAt: Date?, now: Date) -> Bool {
        guard let lastSyncedAt else { return false }
        return now.timeIntervalSince(lastSyncedAt) >= reconciliationInterval
    }

    private func enqueueAllLocalRecords(scheduleSync: Bool = true) {
        enqueueAllBeforeNextSync = true
        if scheduleSync { scheduleEventDrivenSync() }
    }

    private func enqueueLocalRecords(_ ids: Set<UUID>) {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled), !ids.isEmpty else { return }
        if syncTask != nil { recordIDsQueuedDuringSync.formUnion(ids) }
        var pending = loadIDs(forKey: Self.pendingRecordIDsKey)
        pending.formUnion(ids)
        persistIDs(pending, forKey: Self.pendingRecordIDsKey)
        scheduleEventDrivenSync()
    }

    private func scheduleEventDrivenSync(
        fullScan: Bool = false,
        operationURLs: Set<URL> = [],
        forcedRecordIDs: Set<UUID> = []
    ) {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) else { return }
        scheduledFullScan = scheduledFullScan || fullScan
        scheduledOperationURLs.formUnion(operationURLs)
        scheduledRecordIDs.formUnion(forcedRecordIDs)
        eventSyncTask?.cancel()
        eventSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            let nextFullScan = self.scheduledFullScan
            let nextOperationURLs = self.scheduledOperationURLs
            let nextRecordIDs = self.scheduledRecordIDs
            self.scheduledFullScan = false
            self.scheduledOperationURLs.removeAll()
            self.scheduledRecordIDs.removeAll()
            self.syncNow(
                fullScan: nextFullScan,
                operationURLs: nextOperationURLs,
                forcedRecordIDs: nextRecordIDs,
                repairLocalStore: false
            )
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard retryTask == nil,
            defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.syncNow(fullScan: true, repairLocalStore: false)
        }
    }

    var isSyncRunningForTesting: Bool { syncTask != nil }

    private nonisolated func loadIDs(forKey key: String) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private nonisolated func persistIDs(_ ids: Set<UUID>, forKey key: String) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }

    private nonisolated func performSync(
        modelContainer: ModelContainer,
        enqueueAll: Bool,
        fullScan: Bool,
        operationURLs: Set<URL>,
        forcedRecordIDs: Set<UUID>,
        repairLocalStore: Bool
    ) throws -> SyncOutcome {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Finder can expose an iCloud directory before its descendants are locally materialized.
        // Request the usage operation tree on every startup/retry so remote history arrives
        // without requiring the user to choose Download Now in Finder. This intentionally does
        // not request Blobs/Audio, which remains an independent opt-in, on-demand path.
        syncCore.requestDownload(in: .usage)
        syncCore.prepareDeviceIdentity()
        let modelContext = ModelContext(modelContainer)
        if enqueueAll {
            let allIDs = Set(try modelContext.fetch(FetchDescriptor<Transcription>()).map(\.id))
            var pending = loadIDs(forKey: Self.pendingRecordIDsKey)
            pending.formUnion(allIDs)
            persistIDs(pending, forKey: Self.pendingRecordIDsKey)
        }
        let didScanLegacyUsage = try migrateLegacyUsageIfNeeded()
        let knownOperationIDs = Set(appliedOperationIDs.values.flatMap { $0 })
        let loaded = try loadRegister(
            knownOperationIDs: knownOperationIDs,
            fullScan: fullScan || didScanLegacyUsage,
            operationURLs: operationURLs
        )
        var register = loaded.register
        appliedOperationIDs = activeOperationIDs(in: register)
        var affectedKeys = loaded.affectedKeys
        affectedKeys.formUnion(forcedRecordIDs.map(Self.transcriptionKey))
        if fullScan {
            affectedKeys.formUnion(allPendingAudioRecordIDs().map(Self.transcriptionKey))
        }
        let lastFullMaterialization = defaults.object(
            forKey: Self.lastFullMaterializationKey) as? Date
        let fullMaterializationIsDue = lastFullMaterialization.map {
            Date().timeIntervalSince($0) >= Self.fullMaterializationInterval
        } ?? true
        let shouldRepairLocalStore = repairLocalStore || fullMaterializationIsDue
        if shouldRepairLocalStore {
            affectedKeys.formUnion(register.candidatesByKey.keys)
        }
        let isBootstrap = !defaults.bool(forKey: Self.localBootstrapCompletedKey)
        let pendingRecords = loadIDs(forKey: Self.pendingRecordIDsKey)
        let pendingDeletions = loadIDs(forKey: Self.pendingGlobalDeletionIDsKey)
        let exported = try appendLocalChanges(
            recordIDs: pendingRecords.subtracting(pendingDeletions),
            register: register,
            isBootstrap: isBootstrap,
            modelContext: modelContext
        )
        let deleted = try appendGlobalDeletions(pendingDeletions, register: register)
        let appended = exported + deleted
        for batch in appended {
            affectedKeys.formUnion(register.apply(batch.envelope, batch: .init(mutations: batch.mutations)))
        }
        if !appended.isEmpty {
            try syncCore.updateIncrementalCheckpoint(
                register: register,
                incorporating: appended.map(\.envelope),
                domain: .usage
            )
        }
        let applyResult = try apply(
            register: register,
            affectedKeys: affectedKeys,
            modelContext: modelContext
        )
        appliedOperationIDs = activeOperationIDs(in: register)
        defaults.removeObject(forKey: Self.appliedOperationIDsKey)
        if shouldRepairLocalStore {
            defaults.set(Date(), forKey: Self.lastFullMaterializationKey)
        }
        persistAudioVerificationCacheIfNeeded()
        return SyncOutcome(
            processedRecordIDs: pendingRecords,
            processedDeletionIDs: pendingDeletions,
            synchronizedRecordCount: activeTranscriptionCount(in: register),
            conflictCount: register.conflictCount,
            exportCandidateCount: pendingRecords.count + pendingDeletions.count,
            importCandidateCount: applyResult.importCount,
            usedLegacyScan: didScanLegacyUsage,
            didChangeLocalStore: applyResult.didChange,
            cloudAudioRecordIDs: allPendingAudioRecordIDs(),
            latestRemoteDeviceName: loaded.latestRemoteEnvelope?.authorDisplayName
        )
    }

    private nonisolated func appendLocalChanges(
        recordIDs: Set<UUID>,
        register: VoiceInkSyncRegisterState,
        isBootstrap: Bool,
        modelContext: ModelContext
    ) throws -> [AppendedBatch] {
        guard !recordIDs.isEmpty else { return [] }
        let transcriptions = try fetchTranscriptions(ids: recordIDs, modelContext: modelContext)
        let transcriptionByID = Dictionary(grouping: transcriptions, by: \.id).compactMapValues {
            Self.preferredTranscription(in: $0)
        }
        let metrics = try fetchSessionMetrics(transcriptionIDs: recordIDs, modelContext: modelContext)
        let metricsByRecord = Dictionary(grouping: metrics, by: \.transcriptionId)
        var allMutations: [VoiceInkSyncMutation] = []
        var transcriptionsByKey: [String: Transcription] = [:]
        var metricsByKey: [String: SessionMetric] = [:]

        for recordID in recordIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let transcription = transcriptionByID[recordID] else { continue }
            let transcriptionKey = Self.transcriptionKey(recordID)
            let previousValue = register.selectedCandidate(for: transcriptionKey, deleteWins: true)
                .flatMap { $0.mutation.value }
                .flatMap { try? PropertyListDecoder().decode(TranscriptionValue.self, from: $0) }
            let audio = try prepareAudioDescriptor(for: transcription) ?? previousValue?.audio
            let value = TranscriptionValue(transcription: Self.payload(from: transcription), audio: audio)
            let valueData = try Self.encode(value)
            var mutations: [VoiceInkSyncMutation] = []
            if shouldWrite(
                current: valueData,
                selected: register.selectedCandidate(for: transcriptionKey, deleteWins: true).flatMap { $0.mutation.value },
                key: transcriptionKey,
                isBootstrap: isBootstrap
            ) {
                mutations.append(VoiceInkSyncMutation(
                    key: transcriptionKey,
                    value: valueData,
                    supersededOperationIDs: isBootstrap ? [] : appliedOperationIDs[transcriptionKey] ?? []
                ))
            }

            let localMetrics = Dictionary(
                grouping: metricsByRecord[recordID] ?? [], by: \.id
            ).compactMapValues { Self.preferredMetric(in: $0) }.values
            for metric in localMetrics.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let key = Self.metricKey(recordID: recordID, metricID: metric.id)
                let data = try Self.encode(Self.payload(from: metric))
                if shouldWrite(
                    current: data,
                    selected: register.selectedCandidate(for: key, deleteWins: true).flatMap { $0.mutation.value },
                    key: key,
                    isBootstrap: isBootstrap
                ) {
                    mutations.append(VoiceInkSyncMutation(
                        key: key,
                        value: data,
                        supersededOperationIDs: isBootstrap ? [] : appliedOperationIDs[key] ?? []
                    ))
                    metricsByKey[key] = metric
                }
            }

            guard !mutations.isEmpty else { continue }
            allMutations.append(contentsOf: mutations)
            if mutations.contains(where: { $0.key == transcriptionKey }) {
                transcriptionsByKey[transcriptionKey] = transcription
            }
        }
        guard !allMutations.isEmpty else { return [] }
        let batches = try syncCore.appendChunked(allMutations, domain: .usage)
        for batch in batches {
            for mutation in batch.mutations {
                if let transcription = transcriptionsByKey[mutation.key] {
                    transcription.syncOriginDeviceID = batch.envelope.authorDeviceID
                    transcription.syncModifiedAt = batch.envelope.createdAt
                    transcription.syncRevisionID = batch.envelope.operationID
                } else if let metric = metricsByKey[mutation.key] {
                    metric.syncOriginDeviceID = batch.envelope.authorDeviceID
                    metric.syncModifiedAt = batch.envelope.createdAt
                    metric.syncRevisionID = batch.envelope.operationID
                }
            }
        }
        try modelContext.save()
        return batches
    }

    private nonisolated func shouldWrite(
        current: Data,
        selected: Data?,
        key: String,
        isBootstrap: Bool
    ) -> Bool {
        if current != selected { return true }
        return !isBootstrap && (appliedOperationIDs[key]?.count ?? 0) > 1
    }

    private nonisolated func appendGlobalDeletions(
        _ recordIDs: Set<UUID>,
        register: VoiceInkSyncRegisterState
    ) throws -> [AppendedBatch] {
        var mutations: [VoiceInkSyncMutation] = []
        for recordID in recordIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let transcriptionKey = Self.transcriptionKey(recordID)
            mutations.append(VoiceInkSyncMutation(
                key: transcriptionKey, value: nil,
                supersededOperationIDs: appliedOperationIDs[transcriptionKey] ?? []
            ))
            for key in appliedOperationIDs.keys
                .filter({ $0.hasPrefix(Self.metricPrefix(recordID)) }).sorted()
            {
                mutations.append(VoiceInkSyncMutation(
                    key: key, value: nil, supersededOperationIDs: appliedOperationIDs[key] ?? []
                ))
            }
        }
        return try syncCore.appendChunked(mutations, domain: .usage)
    }

    private nonisolated func apply(
        register: VoiceInkSyncRegisterState,
        affectedKeys: Set<String>,
        modelContext: ModelContext
    ) throws -> (importCount: Int, didChange: Bool) {
        guard !affectedKeys.isEmpty else {
            return (0, false)
        }
        let suppressed = loadIDs(forKey: Self.locallySuppressedRecordIDsKey)
        let audioEnabled = defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        let affectedRecordIDs = Set(affectedKeys.compactMap { key -> UUID? in
            Self.recordID(fromTranscriptionKey: key) ?? Self.metricIDs(from: key)?.recordID
        })
        let localTranscriptions = try fetchTranscriptions(
            ids: affectedRecordIDs, modelContext: modelContext)
        var transcriptionsByID = Dictionary(grouping: localTranscriptions, by: \.id)
        let localMetrics = try fetchSessionMetrics(
            transcriptionIDs: affectedRecordIDs, modelContext: modelContext)
        var metricsByLogicalID = Dictionary(grouping: localMetrics) {
            MetricLogicalID(transcriptionID: $0.transcriptionId, metricID: $0.id)
        }
        var changed = false
        var importCount = 0

        for key in affectedKeys.filter({ $0.hasPrefix("transcription/") }).sorted() {
            guard let recordID = Self.recordID(fromTranscriptionKey: key),
                let candidate = register.selectedCandidate(for: key, deleteWins: true)
            else { continue }
            guard let data = candidate.mutation.value else {
                removeRecordFromPendingAudio(recordID)
                let existingRows = transcriptionsByID.removeValue(forKey: recordID) ?? []
                let deletedMetrics = deleteMetrics(
                    for: recordID, metricsByLogicalID: &metricsByLogicalID, context: modelContext)
                if !existingRows.isEmpty {
                    for existing in existingRows { modelContext.delete(existing) }
                }
                if !existingRows.isEmpty || deletedMetrics {
                    changed = true
                    importCount += 1
                }
                continue
            }
            guard !suppressed.contains(recordID),
                let value = try? PropertyListDecoder().decode(TranscriptionValue.self, from: data)
            else { continue }
            removeRecordFromPendingAudio(recordID)
            let existing = Self.preferredTranscription(in: transcriptionsByID[recordID] ?? [])
            let transcription = existing ?? Transcription(text: value.transcription.text, duration: value.transcription.duration)
            if existing == nil {
                transcription.id = recordID
                modelContext.insert(transcription)
                transcriptionsByID[recordID] = [transcription]
            }
            let needsApply = existing == nil
                || Self.payload(from: transcription) != value.transcription
                || transcription.syncRevisionID != candidate.envelope.operationID
            if audioEnabled, let audio = value.audio {
                addPendingAudio(audio.sha256, recordID: recordID)
            }
            if needsApply {
                Self.apply(value.transcription, to: transcription)
                transcription.syncOriginDeviceID = candidate.envelope.authorDeviceID
                transcription.syncModifiedAt = candidate.envelope.createdAt
                transcription.syncRevisionID = candidate.envelope.operationID
                changed = true
                importCount += 1
            }
        }

        for key in affectedKeys.filter({ $0.hasPrefix("metric/") }).sorted() {
            guard let ids = Self.metricIDs(from: key),
                let candidate = register.selectedCandidate(for: key, deleteWins: true)
            else { continue }
            let transcriptionKey = Self.transcriptionKey(ids.recordID)
            guard register.selectedCandidate(for: transcriptionKey, deleteWins: true)?.mutation.value != nil,
                !suppressed.contains(ids.recordID)
            else { continue }
            let logicalID = MetricLogicalID(
                transcriptionID: ids.recordID, metricID: ids.metricID)
            guard let data = candidate.mutation.value else {
                if let existingRows = metricsByLogicalID.removeValue(forKey: logicalID) {
                    for existing in existingRows { modelContext.delete(existing) }
                    changed = true
                }
                continue
            }
            guard let payload = try? PropertyListDecoder().decode(MetricPayload.self, from: data),
                payload.transcriptionId == ids.recordID, payload.id == ids.metricID
            else { continue }
            let existing = Self.preferredMetric(in: metricsByLogicalID[logicalID] ?? [])
            let needsApply = existing.map(Self.payload) != payload
                || existing?.syncRevisionID != candidate.envelope.operationID
            if !needsApply { continue }
            let metric = existing ?? SessionMetric(
                transcriptionId: payload.transcriptionId,
                wordCount: payload.wordCount,
                audioDuration: payload.audioDuration,
                transcriptionModelName: payload.transcriptionModelName,
                transcriptionDuration: payload.transcriptionDuration,
                speedFactor: payload.speedFactor,
                modeName: payload.modeName,
                aiEnhancementModelName: payload.aiEnhancementModelName,
                enhancementDuration: payload.enhancementDuration
            )
            if existing == nil {
                modelContext.insert(metric)
                metricsByLogicalID[logicalID] = [metric]
            }
            Self.apply(payload, to: metric)
            metric.syncOriginDeviceID = candidate.envelope.authorDeviceID
            metric.syncModifiedAt = candidate.envelope.createdAt
            metric.syncRevisionID = candidate.envelope.operationID
            changed = true
        }

        if changed {
            try modelContext.save()
        }
        persistPendingAudioRecordIDs()
        return (importCount, changed)
    }

    private nonisolated func deleteMetrics(
        for recordID: UUID,
        metricsByLogicalID: inout [MetricLogicalID: [SessionMetric]],
        context: ModelContext
    ) -> Bool {
        let ids = metricsByLogicalID.keys.filter { $0.transcriptionID == recordID }
        for id in ids {
            for metric in metricsByLogicalID.removeValue(forKey: id) ?? [] {
                context.delete(metric)
            }
        }
        return !ids.isEmpty
    }

    private struct MetricLogicalID: Hashable {
        let transcriptionID: UUID
        let metricID: UUID
    }

    /// Historical imports did not enforce uniqueness for business UUIDs. Keep
    /// every physical row intact, but deterministically choose the most complete
    /// row whenever the sync protocol needs one logical value.
    private nonisolated static func preferredTranscription(
        in values: [Transcription]
    ) -> Transcription? {
        values.max { lhs, rhs in
            let lhsIsCanonical = lhs.syncRevisionID != nil
            let rhsIsCanonical = rhs.syncRevisionID != nil
            if lhsIsCanonical != rhsIsCanonical { return !lhsIsCanonical }
            if lhsIsCanonical {
                let lhsModifiedAt = lhs.syncModifiedAt ?? .distantPast
                let rhsModifiedAt = rhs.syncModifiedAt ?? .distantPast
                if lhsModifiedAt != rhsModifiedAt { return lhsModifiedAt < rhsModifiedAt }
            }
            let lhsScore = transcriptionCompleteness(lhs)
            let rhsScore = transcriptionCompleteness(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return transcriptionTieBreaker(lhs) < transcriptionTieBreaker(rhs)
        }
    }

    private nonisolated static func preferredMetric(in values: [SessionMetric]) -> SessionMetric? {
        values.max { lhs, rhs in
            let lhsIsCanonical = lhs.syncRevisionID != nil
            let rhsIsCanonical = rhs.syncRevisionID != nil
            if lhsIsCanonical != rhsIsCanonical { return !lhsIsCanonical }
            if lhsIsCanonical {
                let lhsModifiedAt = lhs.syncModifiedAt ?? .distantPast
                let rhsModifiedAt = rhs.syncModifiedAt ?? .distantPast
                if lhsModifiedAt != rhsModifiedAt { return lhsModifiedAt < rhsModifiedAt }
            }
            let lhsScore = metricCompleteness(lhs)
            let rhsScore = metricCompleteness(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return metricTieBreaker(lhs) < metricTieBreaker(rhs)
        }
    }

    private nonisolated static func transcriptionCompleteness(_ value: Transcription) -> Int {
        var score = value.text.utf8.count
        score += value.enhancedText?.utf8.count ?? 0
        score += value.performanceData?.count ?? 0
        score += value.audioFileURL == nil ? 0 : 1
        score += value.transcriptionModelName == nil ? 0 : 1
        score += value.aiEnhancementModelName == nil ? 0 : 1
        score += value.promptName == nil ? 0 : 1
        score += value.transcriptionDuration == nil ? 0 : 1
        score += value.enhancementDuration == nil ? 0 : 1
        score += value.modeName == nil ? 0 : 1
        score += value.modeEmoji == nil ? 0 : 1
        score += value.transcriptionStatus == nil ? 0 : 1
        return score
    }

    private nonisolated static func metricCompleteness(_ value: SessionMetric) -> Int {
        var score = value.performanceData?.count ?? 0
        score += value.source == nil ? 0 : 1
        score += value.transcriptionModelName == nil ? 0 : 1
        score += value.transcriptionDuration == nil ? 0 : 1
        score += value.speedFactor == nil ? 0 : 1
        score += value.modeName == nil ? 0 : 1
        score += value.aiEnhancementModelName == nil ? 0 : 1
        score += value.enhancementDuration == nil ? 0 : 1
        score += value.enhancementEstimatedTokenCount == nil ? 0 : 1
        return score
    }

    private nonisolated static func transcriptionTieBreaker(_ value: Transcription) -> String {
        let payloadHash = (try? encode(payload(from: value))).map(VoiceInkSyncEnvelope.sha256) ?? ""
        return [
            payloadHash, value.audioFileURL ?? "", value.syncOriginDeviceID ?? "",
            value.syncRevisionID?.uuidString ?? "",
        ].joined(separator: "|")
    }

    private nonisolated static func metricTieBreaker(_ value: SessionMetric) -> String {
        (try? encode(payload(from: value))).map(VoiceInkSyncEnvelope.sha256) ?? ""
    }

    nonisolated private static let bulkFetchChunkSize = 500

    private nonisolated func fetchTranscriptions(
        ids: Set<UUID>,
        modelContext: ModelContext
    ) throws -> [Transcription] {
        try fetchInChunks(ids) { chunk in
            try modelContext.fetch(FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in
                    chunk.contains(transcription.id)
                }
            ))
        }
    }

    private nonisolated func fetchSessionMetrics(
        transcriptionIDs: Set<UUID>,
        modelContext: ModelContext
    ) throws -> [SessionMetric] {
        try fetchInChunks(transcriptionIDs) { chunk in
            try modelContext.fetch(FetchDescriptor<SessionMetric>(
                predicate: #Predicate<SessionMetric> { metric in
                    chunk.contains(metric.transcriptionId)
                }
            ))
        }
    }

    private nonisolated func fetchInChunks<Value>(
        _ ids: Set<UUID>,
        fetch: (Set<UUID>) throws -> [Value]
    ) throws -> [Value] {
        let ids = Array(ids)
        var values = [Value]()
        for start in stride(from: 0, to: ids.count, by: Self.bulkFetchChunkSize) {
            let end = min(start + Self.bulkFetchChunkSize, ids.count)
            values.append(contentsOf: try fetch(Set(ids[start..<end])))
        }
        return values
    }

    private nonisolated func loadRegister(
        knownOperationIDs: Set<UUID>,
        fullScan: Bool,
        operationURLs: Set<URL>
    ) throws -> (
        register: VoiceInkSyncRegisterState,
        affectedKeys: Set<String>,
        latestRemoteEnvelope: VoiceInkSyncOperationMetadata?
    ) {
        let result = try syncCore.readIncrementally(
            in: .usage,
            hintedOperationURLs: operationURLs,
            fullScan: fullScan
        )
        return (
            result.register,
            result.affectedKeys,
            result.register.latestRemoteEnvelope(
                excludingDeviceID: syncCore.deviceID, knownOperationIDs: knownOperationIDs)
        )
    }

    private nonisolated func activeOperationIDs(in register: VoiceInkSyncRegisterState) -> [String: [UUID]] {
        register.candidatesByKey.reduce(into: [:]) { result, element in
            result[element.key] = register.operationIDs(for: element.key)
        }
    }

    private nonisolated func activeTranscriptionCount(in register: VoiceInkSyncRegisterState) -> Int {
        register.candidatesByKey.keys.filter { key in
            key.hasPrefix("transcription/")
                && register.selectedCandidate(for: key, deleteWins: true)?.mutation.value != nil
        }.count
    }

    private static func decodeOperationIDs(_ data: Data?) -> [String: [UUID]] {
        guard let data,
            let strings = try? PropertyListDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return strings.mapValues { $0.compactMap(UUID.init(uuidString:)) }
    }

    private static func decodePendingAudioRecordIDs(_ data: Data?) -> [String: Set<UUID>] {
        guard let data,
            let strings = try? PropertyListDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return strings.reduce(into: [:]) { result, element in
            let ids = Set(element.value.compactMap(UUID.init(uuidString:)))
            if !ids.isEmpty { result[element.key] = ids }
        }
    }

    private nonisolated func addPendingAudio(_ sha256: String, recordID: UUID) {
        pendingAudioRecordIDsBySHA[sha256, default: []].insert(recordID)
    }

    private nonisolated func removePendingAudio(_ sha256: String, recordID: UUID) {
        pendingAudioRecordIDsBySHA[sha256]?.remove(recordID)
        if pendingAudioRecordIDsBySHA[sha256]?.isEmpty == true {
            pendingAudioRecordIDsBySHA.removeValue(forKey: sha256)
        }
    }

    private nonisolated func removeRecordFromPendingAudio(_ recordID: UUID) {
        for sha256 in Array(pendingAudioRecordIDsBySHA.keys) {
            removePendingAudio(sha256, recordID: recordID)
        }
    }

    private nonisolated func allPendingAudioRecordIDs() -> Set<UUID> {
        Set(pendingAudioRecordIDsBySHA.values.flatMap { $0 })
    }

    private nonisolated func persistPendingAudioRecordIDs() {
        guard !pendingAudioRecordIDsBySHA.isEmpty else {
            defaults.removeObject(forKey: Self.pendingAudioRecordIDsKey)
            return
        }
        let strings = pendingAudioRecordIDsBySHA.mapValues {
            $0.map(\.uuidString).sorted()
        }
        if let data = try? PropertyListEncoder().encode(strings) {
            defaults.set(data, forKey: Self.pendingAudioRecordIDsKey)
        }
    }

    private nonisolated func migrateLegacyUsageIfNeeded() throws -> Bool {
        // Older builds queued legacy audio for eager background downloads. Source audio is now
        // resolved from its legacy or v3 blob only when the user asks to use that recording.
        defaults.removeObject(forKey: Self.metadataPrefix + "legacyPendingAudioDescriptors")
        guard !defaults.bool(forKey: Self.legacyMigrationCompletedKey) else {
            return false
        }
        guard let root = legacyUsageDataDirectoryURL, fileManager.fileExists(atPath: root.path) else {
            defaults.set(true, forKey: Self.legacyMigrationCompletedKey)
            return true
        }
        let recordsRoot = root.appendingPathComponent("Records", isDirectory: true)
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: recordsRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            defaults.set(true, forKey: Self.legacyMigrationCompletedKey)
            return true
        }
        var seen = Set<UUID>()
        var snapshots: [(path: String, snapshot: Snapshot)] = []
        var migratedPaths = Set(defaults.stringArray(forKey: Self.legacyMigratedPathsKey) ?? [])
        var hasPendingDownload = false
        for case let url as URL in enumerator where url.pathExtension == "plist" {
            let relativePath = String(url.path.dropFirst(recordsRoot.path.count))
            if migratedPaths.contains(relativePath) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                hasPendingDownload = true
                continue
            }
            let data = try coordinatedRead(from: url)
            guard let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data),
                snapshot.schemaVersion <= Snapshot.currentSchemaVersion
            else { throw CocoaError(.fileReadCorruptFile) }
            guard seen.insert(snapshot.revisionID).inserted else { continue }
            snapshots.append((relativePath, snapshot))
        }
        snapshots.sort { lhs, rhs in
            if lhs.snapshot.updatedAt != rhs.snapshot.updatedAt {
                return lhs.snapshot.updatedAt < rhs.snapshot.updatedAt
            }
            return lhs.snapshot.revisionID.uuidString < rhs.snapshot.revisionID.uuidString
        }
        var mutations: [VoiceInkSyncMutation] = []
        for entry in snapshots {
            let snapshot = entry.snapshot
            mutations.append(VoiceInkSyncMutation(
                key: Self.transcriptionKey(snapshot.transcription.id),
                value: try Self.encode(TranscriptionValue(
                    transcription: snapshot.transcription, audio: snapshot.audio
                ))
            ))
            if let metric = snapshot.metric {
                mutations.append(VoiceInkSyncMutation(
                    key: Self.metricKey(recordID: metric.transcriptionId, metricID: metric.id),
                    value: try Self.encode(metric)
                ))
            }
        }
        if !mutations.isEmpty {
            // appendChunked derives retry-stable operation IDs from each payload. If a later
            // chunk fails, retrying the same sorted snapshot set reuses earlier files rather
            // than creating duplicates. Advance progress only after every chunk is durable.
            _ = try syncCore.appendChunked(mutations, domain: .usage)
            migratedPaths.formUnion(snapshots.map(\.path))
            defaults.set(migratedPaths.sorted(), forKey: Self.legacyMigratedPathsKey)
        }
        if hasPendingDownload { return true }
        defaults.set(true, forKey: Self.legacyMigrationCompletedKey)
        defaults.removeObject(forKey: Self.legacyMigratedPathsKey)
        return true
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

    private nonisolated var legacyUsageDataDirectoryURL: URL? {
        let root: URL
        if let iCloudDriveRootOverride {
            root = iCloudDriveRootOverride
        } else {
            root = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        }
        return root.appendingPathComponent("VoiceInk/UsageData/v1", isDirectory: true)
    }

    private nonisolated func prepareAudioDescriptor(for transcription: Transcription) throws -> AudioDescriptor? {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled),
            let source = Self.audioURL(from: transcription), fileManager.fileExists(atPath: source.path)
        else { return nil }
        let pathExtension = source.pathExtension.lowercased()
        let descriptor = AudioDescriptor(
            sha256: try cachedSHA256(of: source),
            byteCount: Self.fileSize(at: source),
            fileExtension: Self.isValidFileExtension(pathExtension) ? pathExtension : "bin"
        )
        try installBlob(from: source, descriptor: descriptor)
        return descriptor
    }

    private nonisolated func installBlob(from source: URL, descriptor: AudioDescriptor) throws {
        guard descriptor.isValid else { throw CocoaError(.fileReadCorruptFile) }
        guard let root = syncCore.rootURL else { throw CocoaError(.fileNoSuchFile) }
        let directory = root
            .appendingPathComponent("Blobs/Audio/\(String(descriptor.sha256.prefix(2)))", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(descriptor.sha256).\(descriptor.fileExtension)")
        if fileManager.fileExists(atPath: destination.path) {
            // The cloud copy may be a File Provider placeholder on this Mac. Its content hash
            // is already carried by metadata, so do not download it merely to verify an upload
            // that another device completed. Verification happens if the user requests audio.
            guard try requireCurrentUbiquitousItem(at: destination, startDownload: false) else {
                return
            }
            guard try verifyAudioFile(destination, descriptor: descriptor)
            else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).upload")
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        guard Self.fileSize(at: temporary) == descriptor.byteCount else {
            throw CocoaError(.fileWriteUnknown)
        }
        try rememberVerifiedAudioFile(temporary, sha256: descriptor.sha256)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            if !fileManager.fileExists(atPath: destination.path) { throw error }
        }
        guard Self.fileSize(at: destination) == descriptor.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try rememberVerifiedAudioFile(destination, sha256: descriptor.sha256)
    }

    private enum AudioMaterialization: Sendable {
        case available(URL)
        case pending
    }

    private nonisolated func audioDescriptor(for transcriptionID: UUID) throws -> AudioDescriptor? {
        let register = try syncCore.readIncrementally(
            in: .usage, hintedOperationURLs: [], fullScan: false
        ).register
        guard let candidate = register.selectedCandidate(
            for: Self.transcriptionKey(transcriptionID), deleteWins: true),
            let data = candidate.mutation.value,
            let value = try? PropertyListDecoder().decode(TranscriptionValue.self, from: data)
        else { return nil }
        return value.audio
    }

    private nonisolated func materializeAudio(
        _ audio: AudioDescriptor,
        transcriptionID: UUID
    ) throws -> AudioMaterialization {
        guard audio.isValid else { throw CocoaError(.fileReadCorruptFile) }
        guard let root = syncCore.rootURL else { return .pending }
        let blob = root
            .appendingPathComponent("Blobs/Audio/\(String(audio.sha256.prefix(2)))", isDirectory: true)
            .appendingPathComponent("\(audio.sha256).\(audio.fileExtension)")
        let legacyBlob = legacyUsageDataDirectoryURL?
            .appendingPathComponent(
                "Blobs/Audio/\(String(audio.sha256.prefix(2)))", isDirectory: true
            )
            .appendingPathComponent("\(audio.sha256).\(audio.fileExtension)")
        let candidates = [blob, legacyBlob].compactMap { $0 }
        let existingCandidates = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingCandidates.isEmpty else {
            for candidate in candidates {
                try? fileManager.startDownloadingUbiquitousItem(at: candidate)
            }
            return .pending
        }
        var source: URL?
        var foundCorruptCandidate = false
        for candidate in existingCandidates {
            guard try requireCurrentUbiquitousItem(at: candidate) else { continue }
            guard try verifyAudioFile(candidate, descriptor: audio) else {
                foundCorruptCandidate = true
                continue
            }
            source = candidate
            break
        }
        guard let source else {
            if foundCorruptCandidate { throw CocoaError(.fileReadCorruptFile) }
            return .pending
        }
        let directory = localRecordingsDirectoryOverride ?? Self.localRecordingsDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("synced_\(transcriptionID.uuidString).\(audio.fileExtension)")
        if fileManager.fileExists(atPath: destination.path),
            try verifyAudioFile(destination, descriptor: audio)
        {
            removeObsoleteMaterializations(for: transcriptionID, keeping: destination, in: directory)
            return .available(destination)
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).download")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        guard Self.fileSize(at: temporary) == audio.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try rememberVerifiedAudioFile(temporary, sha256: audio.sha256)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try rememberVerifiedAudioFile(destination, sha256: audio.sha256)
        removeObsoleteMaterializations(for: transcriptionID, keeping: destination, in: directory)
        return .available(destination)
    }

    /// A synchronized record owns one stable local materialization. If the
    /// remote audio format changes, remove the superseded extension only after
    /// the replacement has been fully copied and verified.
    private nonisolated func removeObsoleteMaterializations(
        for transcriptionID: UUID,
        keeping destination: URL,
        in directory: URL
    ) {
        let canonicalStem = "synced_\(transcriptionID.uuidString)"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.standardizedFileURL != destination.standardizedFileURL {
            guard entry.deletingPathExtension().lastPathComponent == canonicalStem,
                (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private nonisolated func requireCurrentUbiquitousItem(
        at url: URL,
        startDownload: Bool = true
    ) throws -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true,
            values?.ubiquitousItemDownloadingStatus != .current
        else { return true }
        if startDownload {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
        return false
    }

    private func startMetadataQueryIfAvailable() {
        guard iCloudDriveRootOverride == nil, metadataQuery == nil, let root = syncCore.rootURL else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        let usageOperations = root.appendingPathComponent("Operations/usage", isDirectory: true)
        let legacyUsage = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UsageData/v1", isDirectory: true)
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, usageOperations.path),
            NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, legacyUsage.path),
        ])
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            metadataQueryObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] notification in
                Task { @MainActor in self?.handleMetadataQueryEvent(notification) }
            })
        }
        metadataQuery = query
        query.start()
    }

    private func stopMetadataQuery() {
        metadataQuery?.stop()
        metadataQuery = nil
        for observer in metadataQueryObservers { NotificationCenter.default.removeObserver(observer) }
        metadataQueryObservers.removeAll()
    }

    private func handleMetadataQueryEvent(_ notification: Notification) {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) else { return }
        if notification.name == .NSMetadataQueryDidFinishGathering {
            // Enabling sync already performs the initial reconciliation. Gathering merely
            // reports that same initial tree; it is not another remote change.
            return
        }
        guard let userInfo = notification.userInfo else { return }
        let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey]
        let urls = keys.flatMap { key in
            (userInfo[key] as? [NSMetadataItem] ?? []).compactMap { item in
                item.value(forAttribute: NSMetadataItemURLKey) as? URL
            }
        }
        let legacyRoot = legacyUsageDataDirectoryURL?.standardizedFileURL.path
        let shouldConsume = urls.contains { url in
            if syncCore.operationLocation(for: url) != nil {
                return syncCore.shouldConsumeRemoteOperation(at: url, domains: [.usage])
            }
            if !defaults.bool(forKey: Self.legacyMigrationCompletedKey),
                let legacyRoot, url.standardizedFileURL.path.hasPrefix(legacyRoot + "/")
            {
                return true
            }
            return false
        }
        if shouldConsume {
            let operationURLs = Set(urls.filter {
                syncCore.operationLocation(for: $0)?.domain == .usage
            })
            scheduleEventDrivenSync(
                operationURLs: operationURLs
            )
        }
    }

    private nonisolated static func isPendingICloudDownload(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }

    private var shouldSkipAutomaticSyncInTests: Bool {
        iCloudDriveRootOverride == nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated private static func transcriptionKey(_ id: UUID) -> String { "transcription/\(id.uuidString)" }
    nonisolated private static func metricPrefix(_ recordID: UUID) -> String { "metric/\(recordID.uuidString)/" }
    nonisolated private static func metricKey(recordID: UUID, metricID: UUID) -> String {
        metricPrefix(recordID) + metricID.uuidString
    }

    nonisolated private static func recordID(fromTranscriptionKey key: String) -> UUID? {
        guard key.hasPrefix("transcription/") else { return nil }
        return UUID(uuidString: String(key.dropFirst("transcription/".count)))
    }

    nonisolated private static func metricIDs(from key: String) -> (recordID: UUID, metricID: UUID)? {
        let components = key.split(separator: "/")
        guard components.count == 3, components[0] == "metric",
            let recordID = UUID(uuidString: String(components[1])),
            let metricID = UUID(uuidString: String(components[2]))
        else { return nil }
        return (recordID, metricID)
    }

    nonisolated private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    nonisolated private static func payload(from transcription: Transcription) -> TranscriptionPayload {
        TranscriptionPayload(
            id: transcription.id, text: transcription.text, enhancedText: transcription.enhancedText,
            timestamp: transcription.timestamp, duration: transcription.duration,
            transcriptionModelName: transcription.transcriptionModelName,
            aiEnhancementModelName: transcription.aiEnhancementModelName, promptName: transcription.promptName,
            transcriptionDuration: transcription.transcriptionDuration, enhancementDuration: transcription.enhancementDuration,
            modeName: transcription.modeName, modeEmoji: transcription.modeEmoji,
            transcriptionStatus: transcription.transcriptionStatus, performanceData: transcription.performanceData
        )
    }

    nonisolated private static func payload(from metric: SessionMetric) -> MetricPayload {
        MetricPayload(
            id: metric.id, transcriptionId: metric.transcriptionId, timestamp: metric.timestamp, source: metric.source,
            wordCount: metric.wordCount, audioDuration: metric.audioDuration,
            transcriptionModelName: metric.transcriptionModelName, transcriptionDuration: metric.transcriptionDuration,
            speedFactor: metric.speedFactor, modeName: metric.modeName,
            aiEnhancementModelName: metric.aiEnhancementModelName, enhancementDuration: metric.enhancementDuration,
            enhancementEstimatedTokenCount: metric.enhancementEstimatedTokenCount, performanceData: metric.performanceData
        )
    }

    nonisolated private static func apply(_ payload: TranscriptionPayload, to transcription: Transcription) {
        transcription.text = payload.text
        transcription.enhancedText = payload.enhancedText
        transcription.timestamp = payload.timestamp
        transcription.duration = payload.duration
        transcription.transcriptionModelName = payload.transcriptionModelName
        transcription.aiEnhancementModelName = payload.aiEnhancementModelName
        transcription.promptName = payload.promptName
        transcription.transcriptionDuration = payload.transcriptionDuration
        transcription.enhancementDuration = payload.enhancementDuration
        transcription.modeName = payload.modeName
        transcription.modeEmoji = payload.modeEmoji
        transcription.transcriptionStatus = payload.transcriptionStatus
        transcription.performanceData = payload.performanceData
    }

    nonisolated private static func apply(_ payload: MetricPayload, to metric: SessionMetric) {
        metric.id = payload.id
        metric.transcriptionId = payload.transcriptionId
        metric.timestamp = payload.timestamp
        metric.source = payload.source
        metric.wordCount = payload.wordCount
        metric.audioDuration = payload.audioDuration
        metric.transcriptionModelName = payload.transcriptionModelName
        metric.transcriptionDuration = payload.transcriptionDuration
        metric.speedFactor = payload.speedFactor
        metric.modeName = payload.modeName
        metric.aiEnhancementModelName = payload.aiEnhancementModelName
        metric.enhancementDuration = payload.enhancementDuration
        metric.enhancementEstimatedTokenCount = payload.enhancementEstimatedTokenCount
        metric.performanceData = payload.performanceData
    }

    nonisolated private static func currentDeviceName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    nonisolated private static func normalizedDeviceName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : String(trimmed.prefix(120))
    }

    nonisolated private static var localRecordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk/Recordings", isDirectory: true)
    }

    nonisolated private static func audioURL(from transcription: Transcription) -> URL? {
        guard let value = transcription.audioFileURL else { return nil }
        return URL(string: value) ?? URL(fileURLWithPath: value)
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let number = attributes[.size] as? NSNumber
        else { return 0 }
        return number.int64Value
    }

    nonisolated private static func isValidFileExtension(_ value: String) -> Bool {
        (1...10).contains(value.count)
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
            }
    }

    private struct VerifiedAudioFile: Codable {
        let byteCount: Int64
        let modifiedAt: TimeInterval
        let fileNumber: UInt64?
        let sha256: String
        let verifiedAt: Date
    }

    private nonisolated var audioVerificationCacheURL: URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            let root = syncCore.rootURL
        else { return nil }
        let directory = caches.appendingPathComponent(
            "com.prakashjoshipax.VoiceInk/ICloudSyncAudioVerification", isDirectory: true)
        let digest = VoiceInkSyncEnvelope.sha256(Data(root.standardizedFileURL.path.utf8))
        return directory.appendingPathComponent("\(digest)-v1.plist")
    }

    private nonisolated func loadAudioVerificationCache() -> [String: VerifiedAudioFile] {
        guard let url = audioVerificationCacheURL,
            let data = try? Data(contentsOf: url),
            let values = try? PropertyListDecoder().decode(
                [String: VerifiedAudioFile].self, from: data)
        else { return [:] }
        return values
    }

    private nonisolated func audioFileMetadata(
        at url: URL
    ) throws -> (byteCount: Int64, modifiedAt: TimeInterval, fileNumber: UInt64?) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else { throw CocoaError(.fileReadUnknown) }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return (byteCount, modifiedAt, fileNumber)
    }

    private nonisolated func cachedSHA256(of url: URL) throws -> String {
        let metadata = try audioFileMetadata(at: url)
        let key = url.standardizedFileURL.path
        if let cached = audioVerificationCache[key],
            cached.byteCount == metadata.byteCount,
            cached.modifiedAt == metadata.modifiedAt,
            cached.fileNumber == metadata.fileNumber
        {
            return cached.sha256
        }
        audioHashCountForTesting += 1
        let sha256 = try Self.sha256(of: url)
        audioVerificationCache[key] = VerifiedAudioFile(
            byteCount: metadata.byteCount,
            modifiedAt: metadata.modifiedAt,
            fileNumber: metadata.fileNumber,
            sha256: sha256,
            verifiedAt: Date()
        )
        audioVerificationCacheIsDirty = true
        return sha256
    }

    private nonisolated func verifyAudioFile(
        _ url: URL,
        descriptor: AudioDescriptor
    ) throws -> Bool {
        let metadata = try audioFileMetadata(at: url)
        guard metadata.byteCount == descriptor.byteCount else { return false }
        return try cachedSHA256(of: url) == descriptor.sha256
    }

    private nonisolated func rememberVerifiedAudioFile(
        _ url: URL,
        sha256: String
    ) throws {
        let metadata = try audioFileMetadata(at: url)
        audioVerificationCache[url.standardizedFileURL.path] = VerifiedAudioFile(
            byteCount: metadata.byteCount,
            modifiedAt: metadata.modifiedAt,
            fileNumber: metadata.fileNumber,
            sha256: sha256,
            verifiedAt: Date()
        )
        audioVerificationCacheIsDirty = true
    }

    private nonisolated func persistAudioVerificationCacheIfNeeded() {
        guard audioVerificationCacheIsDirty, let url = audioVerificationCacheURL else { return }
        let existing = audioVerificationCache.filter { fileManager.fileExists(atPath: $0.key) }
        let sortedEntries = existing.sorted { $0.value.verifiedAt > $1.value.verifiedAt }
        let limited: [String: VerifiedAudioFile] = Dictionary(
            uniqueKeysWithValues: sortedEntries.prefix(5_000).map { ($0.key, $0.value) })
        audioVerificationCache = limited
        guard let data = try? PropertyListEncoder().encode(limited) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil {
            audioVerificationCacheIsDirty = false
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
