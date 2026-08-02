import AppKit
import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Opt-in, local-first synchronization for transcription cases, per-stage
/// performance metrics, and (separately opt-in) source audio. Local SwiftData
/// stores remain authoritative for the running app; iCloud Drive carries
/// portable snapshots and content-addressed audio blobs.
@MainActor
final class CloudUsageDataSyncService: ObservableObject {
    static let shared = CloudUsageDataSyncService()

    struct AudioDescriptor: Codable, Equatable, Sendable {
        let sha256: String
        let byteCount: Int64
        let fileExtension: String
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
        let deliveredText: String?
        let finalEditedText: String?
        let pasteTargetApplicationName: String?
        let pasteTargetBundleIdentifier: String?
        let pasteTargetElementRole: String?
        let pasteTrackingStatus: String?
        let pasteStartedAt: Date?
        let pasteTrackingFinishedAt: Date?
        let postPasteEditHistoryData: Data?
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

    struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let revisionID: UUID
        let sourceDeviceID: String
        let updatedAt: Date
        let transcription: TranscriptionPayload
        let metric: MetricPayload?
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

    var statusText: String { state.displayText }
    var errorText: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    var usageDataDirectoryURL: URL? {
        iCloudDriveRootURL?.appendingPathComponent("VoiceInk/UsageData/v1", isDirectory: true)
    }

    private struct ExportItem: Sendable {
        let sourceDeviceID: String
        let updatedAt: Date
        let transcription: TranscriptionPayload
        let metric: MetricPayload?
        let audioURL: URL?
    }

    private struct ImportedItem: Sendable {
        let snapshot: Snapshot
        let localAudioURL: URL?
    }

    private static let metadataPrefix = "CloudUsageDataSync."
    private static let deviceIDKey = metadataPrefix + "deviceID"
    private static let appliedRevisionsKey = metadataPrefix + "appliedRevisions"
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let iCloudDriveRootOverride: URL?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CloudUsageDataSync")
    private var modelContext: ModelContext?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var syncTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDriveRootURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDriveRootOverride = iCloudDriveRootURL
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        installObserversIfNeeded()
        setEnabled(defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled))
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        timer?.invalidate()
        timer = nil
        syncTask?.cancel()
        syncTask = nil

        guard enabled else {
            state = .disabled
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        syncNow()
    }

    func setAudioEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        if defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled) {
            syncNow()
        }
    }

    func syncNow() {
        guard defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled), syncTask == nil else { return }
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            await self.performSync()
        }
    }

    func revealUsageData() {
        guard let usageDataDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([usageDataDirectoryURL])
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        for name in [
            Notification.Name.transcriptionCompleted,
            Notification.Name.sessionMetricsDidChange,
            NSApplication.didBecomeActiveNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.syncNow() }
                })
        }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            })
    }

    private func performSync() async {
        guard let modelContext, let root = usageDataDirectoryURL else {
            state = .waitingForICloud
            return
        }

        state = .syncing
        do {
            let deviceID = self.deviceID
            let exports = try collectExportItems(modelContext: modelContext, deviceID: deviceID)
            let audioEnabled = defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
            try await Task.detached(priority: .utility) {
                try Self.writeExports(exports, root: root, audioEnabled: audioEnabled)
            }.value

            let imported = try await Task.detached(priority: .utility) {
                try Self.readImports(
                    root: root,
                    localRecordingsDirectory: Self.localRecordingsDirectory,
                    audioEnabled: audioEnabled
                )
            }.value
            try applyImports(imported, modelContext: modelContext, localDeviceID: deviceID)

            synchronizedRecordCount = imported.count
            lastSyncedAt = Date()
            state = .synced
            logger.notice(
                "Usage sync completed exports=\(exports.count, privacy: .public) imports=\(imported.count, privacy: .public) audio=\(audioEnabled, privacy: .public)"
            )
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Usage sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func collectExportItems(modelContext: ModelContext, deviceID: String) throws -> [ExportItem] {
        let metrics = try modelContext.fetch(FetchDescriptor<SessionMetric>())
        let metricsByTranscription = Dictionary(metrics.map { ($0.transcriptionId, $0) }, uniquingKeysWith: { first, _ in first })
        let transcriptions = try modelContext.fetch(FetchDescriptor<Transcription>())
        var didChangeOrigin = false
        var result: [ExportItem] = []

        for transcription in transcriptions {
            if transcription.syncOriginDeviceID == nil {
                transcription.syncOriginDeviceID = deviceID
                transcription.syncModifiedAt = transcription.syncModifiedAt ?? transcription.timestamp
                didChangeOrigin = true
            }
            result.append(
                ExportItem(
                    sourceDeviceID: deviceID,
                    updatedAt: effectiveModifiedAt(for: transcription),
                    transcription: Self.payload(from: transcription),
                    metric: metricsByTranscription[transcription.id].map(Self.payload),
                    audioURL: Self.audioURL(from: transcription)
                ))
        }
        if didChangeOrigin { try modelContext.save() }
        return result
    }

    private func applyImports(
        _ imports: [ImportedItem],
        modelContext: ModelContext,
        localDeviceID: String
    ) throws {
        var changed = false
        var appliedRevisions = loadAppliedRevisions()
        for item in imports where item.snapshot.sourceDeviceID != localDeviceID {
            let payload = item.snapshot.transcription
            let recordKey = payload.id.uuidString
            let revisionValue = item.snapshot.revisionID.uuidString
            guard appliedRevisions[recordKey] != revisionValue else { continue }
            var descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in transcription.id == payload.id }
            )
            descriptor.fetchLimit = 1
            let existing = try modelContext.fetch(descriptor).first

            if existing?.syncRevisionID == item.snapshot.revisionID {
                appliedRevisions[recordKey] = revisionValue
                continue
            }
            let transcription = existing ?? Transcription(text: payload.text, duration: payload.duration)
            if existing == nil {
                transcription.id = payload.id
                modelContext.insert(transcription)
            }
            Self.apply(payload, to: transcription)
            transcription.syncOriginDeviceID = item.snapshot.sourceDeviceID
            transcription.syncModifiedAt = item.snapshot.updatedAt
            transcription.syncRevisionID = item.snapshot.revisionID
            if let localAudioURL = item.localAudioURL {
                transcription.audioFileURL = localAudioURL.absoluteString
            }

            if let metricPayload = item.snapshot.metric {
                var metricDescriptor = FetchDescriptor<SessionMetric>(
                    predicate: #Predicate<SessionMetric> { metric in metric.transcriptionId == payload.id }
                )
                metricDescriptor.fetchLimit = 1
                let existingMetric = try modelContext.fetch(metricDescriptor).first
                let metric = existingMetric
                    ?? SessionMetric(
                        transcriptionId: payload.id,
                        wordCount: metricPayload.wordCount,
                        audioDuration: metricPayload.audioDuration,
                        transcriptionModelName: metricPayload.transcriptionModelName,
                        transcriptionDuration: metricPayload.transcriptionDuration,
                        speedFactor: metricPayload.speedFactor,
                        modeName: metricPayload.modeName,
                        aiEnhancementModelName: metricPayload.aiEnhancementModelName,
                        enhancementDuration: metricPayload.enhancementDuration
                    )
                if existingMetric == nil { modelContext.insert(metric) }
                Self.apply(metricPayload, to: metric)
            }
            appliedRevisions[recordKey] = revisionValue
            changed = true
        }

        saveAppliedRevisions(appliedRevisions)

        if changed {
            try modelContext.save()
            DashboardStatsCache.shared.markStale()
            NotificationCenter.default.post(name: .transcriptionCompleted, object: nil)
            NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
        }
    }

    private func loadAppliedRevisions() -> [String: String] {
        guard let data = defaults.data(forKey: Self.appliedRevisionsKey),
            let value = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return value
    }

    private func saveAppliedRevisions(_ value: [String: String]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.appliedRevisionsKey)
    }

    private func effectiveModifiedAt(for transcription: Transcription) -> Date {
        let editDate = transcription.postPasteEditRecords.last?.timestamp
        return [transcription.syncModifiedAt, transcription.pasteTrackingFinishedAt, editDate, transcription.timestamp]
            .compactMap { $0 }
            .max() ?? transcription.timestamp
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

    private var deviceID: String {
        if let existing = defaults.string(forKey: Self.deviceIDKey) { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: Self.deviceIDKey)
        return created
    }

    nonisolated private static var localRecordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk/Recordings", isDirectory: true)
    }

    nonisolated private static func writeExports(
        _ exports: [ExportItem],
        root: URL,
        audioEnabled: Bool
    ) throws {
        let recordsRoot = root.appendingPathComponent("Records", isDirectory: true)
        let blobsRoot = root.appendingPathComponent("Blobs/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: recordsRoot, withIntermediateDirectories: true)
        if audioEnabled { try FileManager.default.createDirectory(at: blobsRoot, withIntermediateDirectories: true) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        for item in exports {
            let recordDirectory = recordsRoot.appendingPathComponent(item.transcription.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
            let snapshotURL = recordDirectory.appendingPathComponent(item.sourceDeviceID + ".plist")
            let previous: Snapshot?
            if let data = try? Data(contentsOf: snapshotURL) {
                previous = try? PropertyListDecoder().decode(Snapshot.self, from: data)
            } else {
                previous = nil
            }

            var audio = previous?.audio ?? newestAudioDescriptor(in: recordDirectory)
            if audioEnabled, let audioURL = item.audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
                let byteCount = fileSize(at: audioURL)
                if audio?.byteCount != byteCount {
                    let digest = try sha256(of: audioURL)
                    let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension.lowercased()
                    audio = AudioDescriptor(sha256: digest, byteCount: byteCount, fileExtension: ext)
                }
                if let audio {
                    let blobDirectory = blobsRoot.appendingPathComponent(String(audio.sha256.prefix(2)), isDirectory: true)
                    try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
                    let blobURL = blobDirectory.appendingPathComponent("\(audio.sha256).\(audio.fileExtension)")
                    if !FileManager.default.fileExists(atPath: blobURL.path) {
                        let temporaryURL = blobDirectory.appendingPathComponent(".\(UUID().uuidString).upload")
                        try FileManager.default.copyItem(at: audioURL, to: temporaryURL)
                        guard try sha256(of: temporaryURL) == audio.sha256 else {
                            try? FileManager.default.removeItem(at: temporaryURL)
                            throw CocoaError(.fileWriteUnknown)
                        }
                        do {
                            try FileManager.default.moveItem(at: temporaryURL, to: blobURL)
                        } catch {
                            try? FileManager.default.removeItem(at: temporaryURL)
                            if !FileManager.default.fileExists(atPath: blobURL.path) { throw error }
                        }
                    }
                }
            }

            if let previous,
                previous.transcription == item.transcription,
                previous.metric == item.metric,
                previous.audio == audio
            {
                continue
            }

            let snapshot = Snapshot(
                schemaVersion: Snapshot.currentSchemaVersion,
                revisionID: UUID(),
                sourceDeviceID: item.sourceDeviceID,
                updatedAt: Date(),
                transcription: item.transcription,
                metric: item.metric,
                audio: audio
            )
            try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        }
    }

    nonisolated private static func newestAudioDescriptor(in recordDirectory: URL) -> AudioDescriptor? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { url -> Snapshot? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? PropertyListDecoder().decode(Snapshot.self, from: data)
            }
            .filter { $0.audio != nil }
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }?
            .audio
    }

    nonisolated private static func readImports(
        root: URL,
        localRecordingsDirectory: URL,
        audioEnabled: Bool
    ) throws -> [ImportedItem] {
        let recordsRoot = root.appendingPathComponent("Records", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordsRoot.path) else { return [] }
        try FileManager.default.createDirectory(at: localRecordingsDirectory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: recordsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var newest: [UUID: Snapshot] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: fileURL),
                let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data),
                snapshot.schemaVersion <= Snapshot.currentSchemaVersion
            else { continue }
            let id = snapshot.transcription.id
            if let existing = newest[id],
                (existing.updatedAt > snapshot.updatedAt
                    || (existing.updatedAt == snapshot.updatedAt
                        && existing.revisionID.uuidString > snapshot.revisionID.uuidString))
            {
                continue
            }
            newest[id] = snapshot
        }

        return newest.values.map { snapshot in
            let localAudioURL: URL?
            if audioEnabled, let audio = snapshot.audio {
                let destination = localRecordingsDirectory.appendingPathComponent(
                    "synced_\(snapshot.transcription.id.uuidString).\(audio.fileExtension)")
                if FileManager.default.fileExists(atPath: destination.path), fileSize(at: destination) == audio.byteCount {
                    localAudioURL = destination
                } else {
                    let blobURL = root
                        .appendingPathComponent("Blobs/Audio/\(String(audio.sha256.prefix(2)))", isDirectory: true)
                        .appendingPathComponent("\(audio.sha256).\(audio.fileExtension)")
                    if FileManager.default.fileExists(atPath: blobURL.path) {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: blobURL)
                        let temporary = localRecordingsDirectory.appendingPathComponent(".\(UUID().uuidString).download")
                        if (try? FileManager.default.copyItem(at: blobURL, to: temporary)) != nil,
                            (try? sha256(of: temporary)) == audio.sha256
                        {
                            try? FileManager.default.removeItem(at: destination)
                            try? FileManager.default.moveItem(at: temporary, to: destination)
                            localAudioURL = destination
                        } else {
                            try? FileManager.default.removeItem(at: temporary)
                            localAudioURL = nil
                        }
                    } else {
                        localAudioURL = nil
                    }
                }
            } else {
                localAudioURL = nil
            }
            return ImportedItem(snapshot: snapshot, localAudioURL: localAudioURL)
        }
    }

    nonisolated private static func payload(from transcription: Transcription) -> TranscriptionPayload {
        TranscriptionPayload(
            id: transcription.id,
            text: transcription.text,
            enhancedText: transcription.enhancedText,
            timestamp: transcription.timestamp,
            duration: transcription.duration,
            transcriptionModelName: transcription.transcriptionModelName,
            aiEnhancementModelName: transcription.aiEnhancementModelName,
            promptName: transcription.promptName,
            transcriptionDuration: transcription.transcriptionDuration,
            enhancementDuration: transcription.enhancementDuration,
            deliveredText: transcription.deliveredText,
            finalEditedText: transcription.finalEditedText,
            pasteTargetApplicationName: transcription.pasteTargetApplicationName,
            pasteTargetBundleIdentifier: transcription.pasteTargetBundleIdentifier,
            pasteTargetElementRole: transcription.pasteTargetElementRole,
            pasteTrackingStatus: transcription.pasteTrackingStatus,
            pasteStartedAt: transcription.pasteStartedAt,
            pasteTrackingFinishedAt: transcription.pasteTrackingFinishedAt,
            postPasteEditHistoryData: transcription.postPasteEditHistoryData,
            modeName: transcription.modeName,
            modeEmoji: transcription.modeEmoji,
            transcriptionStatus: transcription.transcriptionStatus,
            performanceData: transcription.performanceData
        )
    }

    nonisolated private static func payload(from metric: SessionMetric) -> MetricPayload {
        MetricPayload(
            id: metric.id,
            transcriptionId: metric.transcriptionId,
            timestamp: metric.timestamp,
            source: metric.source,
            wordCount: metric.wordCount,
            audioDuration: metric.audioDuration,
            transcriptionModelName: metric.transcriptionModelName,
            transcriptionDuration: metric.transcriptionDuration,
            speedFactor: metric.speedFactor,
            modeName: metric.modeName,
            aiEnhancementModelName: metric.aiEnhancementModelName,
            enhancementDuration: metric.enhancementDuration,
            enhancementEstimatedTokenCount: metric.enhancementEstimatedTokenCount,
            performanceData: metric.performanceData
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
        transcription.deliveredText = payload.deliveredText
        transcription.finalEditedText = payload.finalEditedText
        transcription.pasteTargetApplicationName = payload.pasteTargetApplicationName
        transcription.pasteTargetBundleIdentifier = payload.pasteTargetBundleIdentifier
        transcription.pasteTargetElementRole = payload.pasteTargetElementRole
        transcription.pasteTrackingStatus = payload.pasteTrackingStatus
        transcription.pasteStartedAt = payload.pasteStartedAt
        transcription.pasteTrackingFinishedAt = payload.pasteTrackingFinishedAt
        transcription.postPasteEditHistoryData = payload.postPasteEditHistoryData
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
