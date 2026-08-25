import Foundation
import OSLog
import SwiftData

struct HistoryStorageSnapshot: Equatable, Sendable {
    var recordCount = 0
    var audioFileCount = 0
    var audioBytes: Int64 = 0
    var estimatedMetadataBytes: Int64 = 0
    var databaseBytes: Int64 = 0

    var managedBytes: Int64 { audioBytes + estimatedMetadataBytes }
    var onDiskBytes: Int64 { audioBytes + databaseBytes }
}

struct HistoryStorageCleanupResult: Equatable, Sendable {
    var reclaimedAudioCount = 0
    var deletedAudioBytes: Int64 = 0
}

/// Calculates history storage on demand and enforces rolling source-audio
/// limits. Usage records and metrics are retained indefinitely; a reclaimed
/// audio ID is synchronized so every device and iCloud converge on the same
/// metadata-only record.
@MainActor
final class HistoryStorageManager: ObservableObject {
    static let shared = HistoryStorageManager()

    @Published private(set) var snapshot = HistoryStorageSnapshot()
    @Published private(set) var isCalculating = false
    @Published private(set) var lastCalculatedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var pendingCapacityActivationDate: Date?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HistoryStorage")
    private var modelContext: ModelContext?
    private var cleanupTimer: Timer?
    private var capacityActivationTask: Task<Void, Never>?
    private var isEnforcingLimits = false

    private init() {}

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext
        let defaults = UserDefaults.standard
        _ = HistoryStorageSettings.currentMegabytes(in: defaults)

        // Existing releases registered unlimited storage. Give the first run
        // of this bounded policy the same grace period as an explicit settings
        // change before enforcing the new 500 MB default.
        if !defaults.bool(forKey: CleanupSettingsKeys.historyStorageCapacityMigrationCompleted) {
            defaults.set(true, forKey: CleanupSettingsKeys.historyStorageCapacityMigrationCompleted)
            let activationDate = Date().addingTimeInterval(HistoryStorageSettings.activationDelay)
            defaults.set(activationDate, forKey: CleanupSettingsKeys.historyStorageLimitActivationDate)
        }

        Task { @MainActor [weak self] in
            await self?.runAutomaticCleanupIfNeeded()
        }

        schedulePendingCapacityActivationIfNeeded()
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(
            withTimeInterval: HistoryStorageSettings.cleanupCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runAutomaticCleanupIfNeeded()
            }
        }
    }

    func scheduleCapacityUpdate(_ megabytes: Int, modelContext: ModelContext) {
        self.modelContext = modelContext
        let normalizedMegabytes = HistoryStorageSettings.normalizedMegabytes(megabytes)
        UserDefaults.standard.set(
            normalizedMegabytes,
            forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes
        )
        scheduleLimitUpdate(modelContext: modelContext)
    }

    func scheduleLimitUpdate(modelContext: ModelContext) {
        self.modelContext = modelContext
        let activationDate = Date().addingTimeInterval(HistoryStorageSettings.activationDelay)
        UserDefaults.standard.set(activationDate, forKey: CleanupSettingsKeys.historyStorageLimitActivationDate)
        pendingCapacityActivationDate = activationDate
        schedulePendingCapacityActivationIfNeeded()
    }

    func refresh(modelContext: ModelContext) async {
        isCalculating = true
        defer { isCalculating = false }

        do {
            snapshot = try calculateSnapshot(modelContext: modelContext)
            lastCalculatedAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to calculate history storage: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func enforceLimits(
        modelContext: ModelContext,
        usageSync: CloudUsageDataSyncService = .shared,
        recordingsDirectoryURL: URL? = nil
    ) async -> HistoryStorageCleanupResult {
        guard !isEnforcingLimits else { return HistoryStorageCleanupResult() }
        isEnforcingLimits = true
        defer { isEnforcingLimits = false }

        let defaults = UserDefaults.standard
        let maximumCount = max(0, defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryRecordCount))
        let maximumMegabytes = HistoryStorageSettings.currentMegabytes(in: defaults)
        let maximumBytes = Int64(maximumMegabytes) * 1_024 * 1_024

        do {
            let descriptor = FetchDescriptor<Transcription>(
                sortBy: [SortDescriptor(\Transcription.timestamp, order: .forward)]
            )
            let records = try modelContext.fetch(descriptor)
            var recordsByAudioPath = [String: [Transcription]]()
            var audioURLByPath = [String: URL]()
            for record in records {
                guard let url = Self.audioURL(
                    for: record, recordingsDirectory: recordingsDirectoryURL),
                    FileManager.default.fileExists(atPath: url.path)
                else { continue }
                let path = url.standardizedFileURL.path
                recordsByAudioPath[path, default: []].append(record)
                audioURLByPath[path] = url
            }
            let audioPaths = recordsByAudioPath.keys.sorted { lhs, rhs in
                let lhsTimestamp = recordsByAudioPath[lhs]?.map(\.timestamp).max() ?? .distantPast
                let rhsTimestamp = recordsByAudioPath[rhs]?.map(\.timestamp).max() ?? .distantPast
                if lhsTimestamp != rhsTimestamp { return lhsTimestamp < rhsTimestamp }
                return lhs < rhs
            }
            var candidates = Array(audioPaths.dropLast())
            var remainingAudioCount = audioPaths.count
            var totalAudioBytes = audioPaths.reduce(Int64(0)) { total, path in
                total + Self.fileSize(at: audioURLByPath[path] ?? URL(fileURLWithPath: path))
            }
            var result = HistoryStorageCleanupResult()

            // Keep the newest audio even when one recording alone exceeds the
            // configured capacity. The UI reports the remaining overage.
            while !candidates.isEmpty,
                Self.shouldDelete(
                    audioCount: remainingAudioCount,
                    audioBytes: totalAudioBytes,
                    maximumAudioCount: maximumCount,
                    maximumBytes: maximumBytes
                )
            {
                let path = candidates.removeFirst()
                let affectedRecords = recordsByAudioPath[path] ?? []
                let audioURL = audioURLByPath[path] ?? URL(fileURLWithPath: path)
                let removedAudioBytes = Self.fileSize(at: audioURL)

                if FileManager.default.fileExists(atPath: audioURL.path) {
                    do {
                        try FileManager.default.removeItem(at: audioURL)
                    } catch {
                        logger.error(
                            "Failed to remove history audio \(audioURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        // Keep the database row so this managed file can be
                        // retried on the next hourly check.
                        continue
                    }
                }
                usageSync.prepareAudioReclamation(Set(affectedRecords.map(\.id)))
                for record in affectedRecords {
                    record.audioFileURL = nil
                }
                remainingAudioCount -= 1
                totalAudioBytes -= removedAudioBytes
                result.reclaimedAudioCount += 1
                result.deletedAudioBytes += removedAudioBytes
            }

            if result.reclaimedAudioCount > 0 {
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                logger.notice(
                    "Applied history limits reclaimedAudio=\(result.reclaimedAudioCount, privacy: .public) deletedAudioBytes=\(result.deletedAudioBytes, privacy: .public)"
                )
            }

            await refresh(modelContext: modelContext)
            return result
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to enforce history limits: \(error.localizedDescription, privacy: .public)")
            return HistoryStorageCleanupResult()
        }
    }

    nonisolated static func shouldDelete(
        audioCount: Int,
        audioBytes: Int64,
        maximumAudioCount: Int,
        maximumBytes: Int64
    ) -> Bool {
        (maximumAudioCount > 0 && audioCount > maximumAudioCount)
            || (maximumBytes > 0 && audioBytes > maximumBytes)
    }

    nonisolated static func isAutomaticCleanupDue(
        now: Date,
        lastCheckDate: Date?,
        activationDate: Date?
    ) -> Bool {
        if let activationDate, now < activationDate {
            return false
        }
        guard let lastCheckDate else { return true }
        return now.timeIntervalSince(lastCheckDate) >= HistoryStorageSettings.cleanupCheckInterval
    }

    private func runAutomaticCleanupIfNeeded(now: Date = Date()) async {
        let defaults = UserDefaults.standard
        let lastCheckDate = defaults.object(
            forKey: CleanupSettingsKeys.lastAutomaticHistoryCleanupDate
        ) as? Date
        let activationDate = defaults.object(
            forKey: CleanupSettingsKeys.historyStorageLimitActivationDate
        ) as? Date
        pendingCapacityActivationDate = activationDate.flatMap { $0 > now ? $0 : nil }

        guard Self.isAutomaticCleanupDue(
            now: now,
            lastCheckDate: lastCheckDate,
            activationDate: activationDate
        ), let modelContext
        else { return }

        defaults.set(now, forKey: CleanupSettingsKeys.lastAutomaticHistoryCleanupDate)
        if activationDate != nil {
            defaults.removeObject(forKey: CleanupSettingsKeys.historyStorageLimitActivationDate)
            pendingCapacityActivationDate = nil
        }
        _ = await enforceLimits(modelContext: modelContext)
    }

    private func schedulePendingCapacityActivationIfNeeded(now: Date = Date()) {
        capacityActivationTask?.cancel()
        guard let activationDate = UserDefaults.standard.object(
            forKey: CleanupSettingsKeys.historyStorageLimitActivationDate
        ) as? Date
        else {
            pendingCapacityActivationDate = nil
            return
        }

        pendingCapacityActivationDate = activationDate > now ? activationDate : nil
        capacityActivationTask = Task { @MainActor [weak self] in
            let delay = max(0, activationDate.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            // A settings change is applied once after its debounce window,
            // independent of the regular hourly check cadence.
            UserDefaults.standard.removeObject(forKey: CleanupSettingsKeys.historyStorageLimitActivationDate)
            UserDefaults.standard.set(Date(), forKey: CleanupSettingsKeys.lastAutomaticHistoryCleanupDate)
            self.pendingCapacityActivationDate = nil
            if let modelContext = self.modelContext {
                _ = await self.enforceLimits(modelContext: modelContext)
            }
        }
    }

    private func calculateSnapshot(modelContext: ModelContext) throws -> HistoryStorageSnapshot {
        let records = try modelContext.fetch(FetchDescriptor<Transcription>())
        var result = HistoryStorageSnapshot(recordCount: records.count)
        var seenAudioPaths: Set<String> = []

        for record in records {
            result.estimatedMetadataBytes += Self.estimatedMetadataSize(for: record)
            guard let url = Self.audioURL(for: record), seenAudioPaths.insert(url.path).inserted else { continue }
            let bytes = Self.fileSize(at: url)
            if bytes > 0 {
                result.audioFileCount += 1
                result.audioBytes += bytes
            }
        }

        let appSupport = Self.appSupportDirectory
        let storeNames = ["default.store", "stats.store"]
        let suffixes = ["", "-wal", "-shm"]
        for store in storeNames {
            for suffix in suffixes {
                result.databaseBytes += Self.fileSize(at: appSupport.appendingPathComponent(store + suffix))
            }
        }
        return result
    }

    private static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
    }

    private static func managedSize(for transcription: Transcription) -> Int64 {
        estimatedMetadataSize(for: transcription) + audioSize(for: transcription)
    }

    private static func estimatedMetadataSize(for transcription: Transcription) -> Int64 {
        let strings: [String?] = [
            transcription.text, transcription.enhancedText, transcription.audioFileURL,
            transcription.transcriptionModelName, transcription.aiEnhancementModelName,
            transcription.promptName, transcription.aiRequestSystemMessage, transcription.aiRequestUserMessage,
            transcription.modeName, transcription.modeEmoji,
            transcription.vocabularyBundleIdentifier, transcription.vocabularyDomain,
            transcription.transcriptionStatus,
        ]
        let textBytes = strings.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
        let dataBytes = transcription.performanceData?.count ?? 0
        return Int64(textBytes + dataBytes + 512)
    }

    private static func audioURL(
        for transcription: Transcription,
        recordingsDirectory: URL? = nil
    ) -> URL? {
        guard let value = transcription.audioFileURL else { return nil }
        let url = URL(string: value) ?? URL(fileURLWithPath: value)
        let managedDirectory = recordingsDirectory
            ?? appSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        return isManagedAudioURL(url, recordingsDirectory: managedDirectory) ? url : nil
    }

    nonisolated static func isManagedAudioURL(
        _ url: URL,
        recordingsDirectory: URL
    ) -> Bool {
        guard url.isFileURL else { return false }
        let directoryPath = recordingsDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    private static func audioSize(
        for transcription: Transcription,
        recordingsDirectory: URL? = nil
    ) -> Int64 {
        guard let url = audioURL(
            for: transcription, recordingsDirectory: recordingsDirectory)
        else { return 0 }
        return fileSize(at: url)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}
