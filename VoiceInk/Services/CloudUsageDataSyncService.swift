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

    struct AudioDescriptor: Codable, Equatable, Sendable {
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
    private static let reconciliationInterval: TimeInterval = 5 * 60

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
    private var timer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private var metadataQueryObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var syncTask: Task<Void, Never>?
    private var eventSyncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var syncRequestedWhileRunning = false
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
    }

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
        self.localDeviceName = Self.normalizedDeviceName(deviceName ?? Self.currentDeviceName())
        self.syncCore = ICloudDriveSyncCore(
            defaults: defaults,
            fileManager: fileManager,
            iCloudDriveRootURL: iCloudDriveRootURL
        )
        self.appliedOperationIDs = Self.decodeOperationIDs(defaults.data(forKey: Self.appliedOperationIDsKey))
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

        guard enabled else {
            state = .disabled
            return
        }

        enqueueAllBeforeNextSync = !defaults.bool(forKey: Self.localBootstrapCompletedKey)
        timer = Timer.scheduledTimer(withTimeInterval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        timer?.tolerance = 60
        startMetadataQueryIfAvailable()
        syncNow()
    }

    func setAudioEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        if defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) {
            if enabled {
                enqueueAllBeforeNextSync = true
                scheduleEventDrivenSync()
            } else {
                syncNow()
            }
        }
    }

    func syncNow() {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) else { return }
        guard retryTask == nil else {
            syncRequestedWhileRunning = true
            return
        }
        guard syncTask == nil else {
            syncRequestedWhileRunning = true
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
                    try self.performSync(modelContainer: modelContainer, enqueueAll: shouldEnqueueAll)
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
                    self.state = .failed(error.localizedDescription)
                    self.logger.error("Usage sync failed: \(error.localizedDescription, privacy: .public)")
                    self.scheduleRetry(
                        after: ICloudSyncRetryPolicy.delay(afterFailureCount: self.consecutiveFailureCount)
                    )
                }
            }
            self.syncTask = nil
            let shouldRunAgain = self.syncRequestedWhileRunning
            self.syncRequestedWhileRunning = false
            if (shouldRunAgain || generation != self.syncGeneration), self.retryTask == nil {
                self.syncNow()
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
        ) { [weak self] _ in Task { @MainActor in self?.syncNow() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.syncNow() } })
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

    private func scheduleEventDrivenSync() {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) else { return }
        eventSyncTask?.cancel()
        eventSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.syncNow()
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
            self.syncNow()
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
        enqueueAll: Bool
    ) throws -> SyncOutcome {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let modelContext = ModelContext(modelContainer)
        if enqueueAll {
            let allIDs = Set(try modelContext.fetch(FetchDescriptor<Transcription>()).map(\.id))
            var pending = loadIDs(forKey: Self.pendingRecordIDsKey)
            pending.formUnion(allIDs)
            persistIDs(pending, forKey: Self.pendingRecordIDsKey)
        }
        let usedLegacyScan = try migrateLegacyUsageIfNeeded()
        var register = try loadRegister()
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

        if exported > 0 || deleted > 0 || usedLegacyScan { register = try loadRegister() }
        let applyResult = try apply(register: register, modelContext: modelContext)
        appliedOperationIDs = activeOperationIDs(in: register)
        persistAppliedOperationIDs()
        return SyncOutcome(
            processedRecordIDs: pendingRecords,
            processedDeletionIDs: pendingDeletions,
            synchronizedRecordCount: activeTranscriptionCount(in: register),
            conflictCount: register.conflictCount,
            exportCandidateCount: pendingRecords.count + pendingDeletions.count,
            importCandidateCount: applyResult.importCount,
            usedLegacyScan: usedLegacyScan,
            didChangeLocalStore: applyResult.didChange
        )
    }

    private nonisolated func appendLocalChanges(
        recordIDs: Set<UUID>,
        register: VoiceInkSyncRegisterState,
        isBootstrap: Bool,
        modelContext: ModelContext
    ) throws -> Int {
        guard !recordIDs.isEmpty else { return 0 }
        let transcriptions = try fetchTranscriptions(ids: recordIDs, modelContext: modelContext)
        let transcriptionByID = Dictionary(uniqueKeysWithValues: transcriptions.map { ($0.id, $0) })
        let metrics = try fetchSessionMetrics(transcriptionIDs: recordIDs, modelContext: modelContext)
        let metricsByRecord = Dictionary(grouping: metrics, by: \.transcriptionId)
        var writeCount = 0

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

            let localMetrics = metricsByRecord[recordID] ?? []
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
                }
            }

            guard !mutations.isEmpty else { continue }
            let batches = try syncCore.appendChunked(mutations, domain: .usage)
            if let envelope = batches.first(where: { batch in
                batch.mutations.contains(where: { $0.key == transcriptionKey })
            })?.envelope {
                transcription.syncOriginDeviceID = envelope.authorDeviceID
                transcription.syncModifiedAt = envelope.createdAt
                transcription.syncRevisionID = envelope.operationID
            }
            writeCount += batches.count
        }
        if writeCount > 0 { try modelContext.save() }
        return writeCount
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
    ) throws -> Int {
        var count = 0
        for recordID in recordIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let transcriptionKey = Self.transcriptionKey(recordID)
            var mutations = [VoiceInkSyncMutation(
                key: transcriptionKey, value: nil,
                supersededOperationIDs: appliedOperationIDs[transcriptionKey] ?? []
            )]
            for key in appliedOperationIDs.keys
                .filter({ $0.hasPrefix(Self.metricPrefix(recordID)) }).sorted()
            {
                mutations.append(VoiceInkSyncMutation(
                    key: key, value: nil, supersededOperationIDs: appliedOperationIDs[key] ?? []
                ))
            }
            count += try syncCore.appendChunked(mutations, domain: .usage).count
        }
        return count
    }

    private nonisolated func apply(
        register: VoiceInkSyncRegisterState,
        modelContext: ModelContext
    ) throws -> (importCount: Int, didChange: Bool) {
        let suppressed = loadIDs(forKey: Self.locallySuppressedRecordIDsKey)
        let audioEnabled = defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        let localTranscriptions = try modelContext.fetch(FetchDescriptor<Transcription>())
        var transcriptionByID = Dictionary(uniqueKeysWithValues: localTranscriptions.map { ($0.id, $0) })
        let localMetrics = try modelContext.fetch(FetchDescriptor<SessionMetric>())
        var metricByID = Dictionary(uniqueKeysWithValues: localMetrics.map { ($0.id, $0) })
        var activeRecordIDs = Set<UUID>()
        var changed = false
        var importCount = 0

        for key in register.candidatesByKey.keys.filter({ $0.hasPrefix("transcription/") }).sorted() {
            guard let recordID = Self.recordID(fromTranscriptionKey: key),
                let candidate = register.selectedCandidate(for: key, deleteWins: true)
            else { continue }
            guard let data = candidate.mutation.value else {
                if let existing = transcriptionByID.removeValue(forKey: recordID) {
                    deleteMetrics(for: recordID, metricByID: &metricByID, context: modelContext)
                    modelContext.delete(existing)
                    changed = true
                    importCount += 1
                }
                continue
            }
            guard !suppressed.contains(recordID),
                let value = try? PropertyListDecoder().decode(TranscriptionValue.self, from: data)
            else { continue }
            activeRecordIDs.insert(recordID)
            let existing = transcriptionByID[recordID]
            let transcription = existing ?? Transcription(text: value.transcription.text, duration: value.transcription.duration)
            if existing == nil {
                transcription.id = recordID
                modelContext.insert(transcription)
                transcriptionByID[recordID] = transcription
            }
            let needsApply = existing == nil
                || Self.payload(from: transcription) != value.transcription
                || transcription.syncRevisionID != candidate.envelope.operationID
            var materializedAudioURL: URL?
            if audioEnabled, let audio = value.audio {
                materializedAudioURL = try materializeAudio(audio, transcriptionID: recordID)
            }
            let audioNeedsApply = materializedAudioURL != nil
                && transcription.audioFileURL != materializedAudioURL?.absoluteString
            if needsApply || audioNeedsApply {
                Self.apply(value.transcription, to: transcription)
                transcription.syncOriginDeviceID = candidate.envelope.authorDeviceID
                transcription.syncModifiedAt = candidate.envelope.createdAt
                transcription.syncRevisionID = candidate.envelope.operationID
                if let localURL = materializedAudioURL {
                    transcription.audioFileURL = localURL.absoluteString
                }
                changed = true
                importCount += 1
            }
        }

        for key in register.candidatesByKey.keys.filter({ $0.hasPrefix("metric/") }).sorted() {
            guard let ids = Self.metricIDs(from: key),
                let candidate = register.selectedCandidate(for: key, deleteWins: true)
            else { continue }
            guard activeRecordIDs.contains(ids.recordID), !suppressed.contains(ids.recordID) else { continue }
            guard let data = candidate.mutation.value else {
                if let existing = metricByID.removeValue(forKey: ids.metricID) {
                    modelContext.delete(existing)
                    changed = true
                }
                continue
            }
            guard let payload = try? PropertyListDecoder().decode(MetricPayload.self, from: data),
                payload.transcriptionId == ids.recordID, payload.id == ids.metricID
            else { continue }
            let existing = metricByID[ids.metricID]
            if existing.map(Self.payload) == payload { continue }
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
            if existing == nil { modelContext.insert(metric); metricByID[ids.metricID] = metric }
            Self.apply(payload, to: metric)
            changed = true
        }

        if changed {
            try modelContext.save()
        }
        return (importCount, changed)
    }

    private nonisolated func deleteMetrics(
        for recordID: UUID,
        metricByID: inout [UUID: SessionMetric],
        context: ModelContext
    ) {
        let ids = metricByID.compactMap { id, metric in
            metric.transcriptionId == recordID ? id : nil
        }
        for id in ids {
            if let metric = metricByID.removeValue(forKey: id) { context.delete(metric) }
        }
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

    private nonisolated func loadRegister() throws -> VoiceInkSyncRegisterState {
        var register = VoiceInkSyncRegisterState()
        for envelope in try syncCore.readAll(in: .usage) {
            register.apply(envelope, batch: try syncCore.decodeBatch(from: envelope))
        }
        return register
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

    private nonisolated func persistAppliedOperationIDs() {
        let strings = appliedOperationIDs.mapValues { $0.map(\.uuidString) }
        if let data = try? PropertyListEncoder().encode(strings) {
            defaults.set(data, forKey: Self.appliedOperationIDsKey)
        }
    }

    private static func decodeOperationIDs(_ data: Data?) -> [String: [UUID]] {
        guard let data,
            let strings = try? PropertyListDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return strings.mapValues { $0.compactMap(UUID.init(uuidString:)) }
    }

    private nonisolated func migrateLegacyUsageIfNeeded() throws -> Bool {
        guard !defaults.bool(forKey: Self.legacyMigrationCompletedKey) else { return false }
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
        for entry in snapshots {
            let snapshot = entry.snapshot
            if let audio = snapshot.audio { try copyLegacyAudioBlob(audio, from: root) }
            var mutations = [VoiceInkSyncMutation(
                key: Self.transcriptionKey(snapshot.transcription.id),
                value: try Self.encode(TranscriptionValue(
                    transcription: snapshot.transcription, audio: snapshot.audio
                ))
            )]
            if let metric = snapshot.metric {
                mutations.append(VoiceInkSyncMutation(
                    key: Self.metricKey(recordID: metric.transcriptionId, metricID: metric.id),
                    value: try Self.encode(metric)
                ))
            }
            _ = try syncCore.append(VoiceInkSyncMutationBatch(mutations: mutations), domain: .usage)
            migratedPaths.insert(entry.path)
            defaults.set(migratedPaths.sorted(), forKey: Self.legacyMigratedPathsKey)
        }
        if hasPendingDownload { throw CocoaError(.fileReadNoSuchFile) }
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

    private nonisolated func copyLegacyAudioBlob(_ audio: AudioDescriptor, from legacyRoot: URL) throws {
        guard audio.isValid else { throw CocoaError(.fileReadCorruptFile) }
        let source = legacyRoot
            .appendingPathComponent("Blobs/Audio/\(String(audio.sha256.prefix(2)))", isDirectory: true)
            .appendingPathComponent("\(audio.sha256).\(audio.fileExtension)")
        guard fileManager.fileExists(atPath: source.path) else {
            try? fileManager.startDownloadingUbiquitousItem(at: source)
            throw CocoaError(.fileReadNoSuchFile)
        }
        try requireCurrentUbiquitousItem(at: source)
        guard Self.fileSize(at: source) == audio.byteCount,
            try Self.sha256(of: source) == audio.sha256
        else { throw CocoaError(.fileReadCorruptFile) }
        try installBlob(from: source, descriptor: audio)
    }

    private nonisolated func prepareAudioDescriptor(for transcription: Transcription) throws -> AudioDescriptor? {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled),
            let source = Self.audioURL(from: transcription), fileManager.fileExists(atPath: source.path)
        else { return nil }
        let pathExtension = source.pathExtension.lowercased()
        let descriptor = AudioDescriptor(
            sha256: try Self.sha256(of: source),
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
            try requireCurrentUbiquitousItem(at: destination)
            guard Self.fileSize(at: destination) == descriptor.byteCount,
                try Self.sha256(of: destination) == descriptor.sha256
            else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).upload")
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        guard Self.fileSize(at: temporary) == descriptor.byteCount,
            try Self.sha256(of: temporary) == descriptor.sha256
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            if !fileManager.fileExists(atPath: destination.path) { throw error }
        }
        guard Self.fileSize(at: destination) == descriptor.byteCount,
            try Self.sha256(of: destination) == descriptor.sha256
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    private nonisolated func materializeAudio(_ audio: AudioDescriptor, transcriptionID: UUID) throws -> URL? {
        guard audio.isValid else { throw CocoaError(.fileReadCorruptFile) }
        guard let root = syncCore.rootURL else { return nil }
        let blob = root
            .appendingPathComponent("Blobs/Audio/\(String(audio.sha256.prefix(2)))", isDirectory: true)
            .appendingPathComponent("\(audio.sha256).\(audio.fileExtension)")
        guard fileManager.fileExists(atPath: blob.path) else {
            try? fileManager.startDownloadingUbiquitousItem(at: blob)
            throw CocoaError(.fileReadNoSuchFile)
        }
        try requireCurrentUbiquitousItem(at: blob)
        guard Self.fileSize(at: blob) == audio.byteCount, try Self.sha256(of: blob) == audio.sha256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = localRecordingsDirectoryOverride ?? Self.localRecordingsDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("synced_\(transcriptionID.uuidString).\(audio.fileExtension)")
        if fileManager.fileExists(atPath: destination.path),
            Self.fileSize(at: destination) == audio.byteCount,
            try Self.sha256(of: destination) == audio.sha256
        {
            return destination
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).download")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: blob, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        guard Self.fileSize(at: temporary) == audio.byteCount, try Self.sha256(of: temporary) == audio.sha256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    private nonisolated func requireCurrentUbiquitousItem(at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true,
            values?.ubiquitousItemDownloadingStatus != .current
        else { return }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func startMetadataQueryIfAvailable() {
        guard iCloudDriveRootOverride == nil, metadataQuery == nil, let root = syncCore.rootURL else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            metadataQueryObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.scheduleEventDrivenSync() } })
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
