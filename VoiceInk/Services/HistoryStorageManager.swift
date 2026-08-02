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
    var deletedRecordCount = 0
    var deletedAudioBytes: Int64 = 0
}

/// Calculates history storage on demand and enforces local-only retention
/// limits. Automatic limit cleanup intentionally does not create cloud
/// tombstones; a small Mac must never delete another device's archive.
@MainActor
final class HistoryStorageManager: ObservableObject {
    static let shared = HistoryStorageManager()

    @Published private(set) var snapshot = HistoryStorageSnapshot()
    @Published private(set) var isCalculating = false
    @Published private(set) var lastCalculatedAt: Date?
    @Published private(set) var lastError: String?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HistoryStorage")
    private var modelContext: ModelContext?
    private var completionObserver: NSObjectProtocol?

    private init() {}

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext
        if completionObserver == nil {
            completionObserver = NotificationCenter.default.addObserver(
                forName: .transcriptionCompleted,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Let completion observers persist/export the new case first.
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let context = self.modelContext else { return }
                    _ = await self.enforceLimits(modelContext: context)
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.enforceLimits(modelContext: modelContext)
        }
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
    func enforceLimits(modelContext: ModelContext) async -> HistoryStorageCleanupResult {
        let defaults = UserDefaults.standard
        let maximumCount = max(0, defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryRecordCount))
        let maximumMegabytes = max(0, defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes))
        let maximumBytes = Int64(maximumMegabytes) * 1_024 * 1_024

        guard maximumCount > 0 || maximumBytes > 0 else {
            return HistoryStorageCleanupResult()
        }

        do {
            let descriptor = FetchDescriptor<Transcription>(
                sortBy: [SortDescriptor(\Transcription.timestamp, order: .forward)]
            )
            var records = try modelContext.fetch(descriptor)
            var sizes = records.map(Self.managedSize)
            var totalManagedBytes = sizes.reduce(Int64(0), +)
            var result = HistoryStorageCleanupResult()

            // Keep the newest case even when one recording alone exceeds the
            // configured capacity. The UI reports the remaining overage.
            while records.count > 1,
                (maximumCount > 0 && records.count > maximumCount)
                    || (maximumBytes > 0 && totalManagedBytes > maximumBytes)
            {
                let oldest = records.removeFirst()
                let oldestSize = sizes.removeFirst()
                let removedAudioBytes = Self.audioSize(for: oldest)

                if let audioURL = Self.audioURL(for: oldest), FileManager.default.fileExists(atPath: audioURL.path) {
                    do {
                        try FileManager.default.removeItem(at: audioURL)
                    } catch {
                        logger.error(
                            "Failed to remove history audio \(audioURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                let transcriptionID = oldest.id
                let metricDescriptor = FetchDescriptor<SessionMetric>(
                    predicate: #Predicate<SessionMetric> { metric in
                        metric.transcriptionId == transcriptionID
                    }
                )
                for metric in try modelContext.fetch(metricDescriptor) {
                    modelContext.delete(metric)
                }
                modelContext.delete(oldest)
                totalManagedBytes -= oldestSize
                result.deletedRecordCount += 1
                result.deletedAudioBytes += removedAudioBytes
            }

            if result.deletedRecordCount > 0 {
                try modelContext.save()
                DashboardStatsCache.shared.markStale()
                NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                logger.notice(
                    "Applied history limits deletedRecords=\(result.deletedRecordCount, privacy: .public) deletedAudioBytes=\(result.deletedAudioBytes, privacy: .public)"
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
        recordCount: Int,
        managedBytes: Int64,
        maximumRecordCount: Int,
        maximumBytes: Int64
    ) -> Bool {
        (maximumRecordCount > 0 && recordCount > maximumRecordCount)
            || (maximumBytes > 0 && managedBytes > maximumBytes)
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
            transcription.deliveredText, transcription.finalEditedText, transcription.pasteTargetApplicationName,
            transcription.pasteTargetBundleIdentifier, transcription.pasteTargetWindowTitle,
            transcription.pasteTargetElementRole, transcription.pasteTargetElementIdentifier,
            transcription.pasteTrackingStatus, transcription.modeName, transcription.modeEmoji,
            transcription.transcriptionStatus,
        ]
        let textBytes = strings.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
        let dataBytes = (transcription.postPasteEditHistoryData?.count ?? 0)
            + (transcription.performanceData?.count ?? 0)
        return Int64(textBytes + dataBytes + 512)
    }

    private static func audioURL(for transcription: Transcription) -> URL? {
        guard let value = transcription.audioFileURL else { return nil }
        return URL(string: value) ?? URL(fileURLWithPath: value)
    }

    private static func audioSize(for transcription: Transcription) -> Int64 {
        guard let url = audioURL(for: transcription) else { return 0 }
        return fileSize(at: url)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}
