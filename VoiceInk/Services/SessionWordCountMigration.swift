import Foundation
import OSLog
import SwiftData

/// Additive, retryable migration. Rows without retained text deliberately stay legacy.
enum SessionWordCountMigration {
    static let didBackfillCountsKey = "wordCountBackfill"

    static func applySyncedCount(_ count: Int, version: Int?, to metric: SessionMetric) {
        guard (version ?? 1) >= (metric.wordCountVersion ?? 1) else { return }
        metric.wordCount = count
        metric.wordCountVersion = version
    }

    @discardableResult
    static func update(
        _ metric: SessionMetric, from transcription: Transcription,
        recountCurrentVersion: Bool = false
    ) -> Bool {
        let version = metric.wordCountVersion ?? 1
        guard version < WordCounter.currentVersion
                || (recountCurrentVersion && version == WordCounter.currentVersion),
            metric.transcriptionId == transcription.id,
            transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue
        else { return false }

        let text: String
        if let enhanced = transcription.enhancedText,
            transcription.enhancementDuration != nil, !enhanced.isEmpty
        {
            text = enhanced
        } else {
            text = transcription.text
        }
        // Retention may leave an empty shell. Do not erase its historical count.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let count = WordCounter.count(in: text)
        guard metric.wordCount != count || metric.wordCountVersion != WordCounter.currentVersion else {
            return false
        }
        metric.wordCount = count
        metric.wordCountVersion = WordCounter.currentVersion
        return true
    }

    static func backfill(
        in context: ModelContext,
        didSaveBatch: ([UUID]) throws -> Void = { _ in }
    ) throws -> [UUID] {
        var updatedIDs: [UUID] = []
        var offset = 0
        // Page over all rows so updating a version cannot shift the fetch offsets.
        while true {
            var descriptor = FetchDescriptor<SessionMetric>(
                sortBy: [
                    SortDescriptor(\SessionMetric.timestamp), SortDescriptor(\SessionMetric.id),
                ])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = 500
            let metrics = try context.fetch(descriptor)
            guard !metrics.isEmpty else { break }
            let legacyMetrics = metrics.filter { ($0.wordCountVersion ?? 1) < WordCounter.currentVersion }
            let ids = legacyMetrics.map(\.transcriptionId)
            if !ids.isEmpty {
                let transcriptions = try context.fetch(FetchDescriptor<Transcription>(
                    predicate: #Predicate { ids.contains($0.id) && $0.transcriptionStatus == "completed" }))
                let transcriptionsByID = Dictionary(grouping: transcriptions, by: \.id)
                var batchIDs: [UUID] = []
                for metric in legacyMetrics {
                    if let transcription = CloudUsageDataSyncService.preferredTranscription(
                        in: transcriptionsByID[metric.transcriptionId] ?? []),
                        update(metric, from: transcription)
                    {
                        // Only local backfill needs an export marker. Imported
                        // text is recounted locally without echoing remote edits.
                        metric.wordCountNeedsSync = true
                        batchIDs.append(metric.transcriptionId)
                    }
                }
                if !batchIDs.isEmpty {
                    try context.save()
                    updatedIDs.append(contentsOf: batchIDs)
                    // Report only durable changes, even if a later page fails.
                    try didSaveBatch(batchIDs)
                }
            }
            offset += metrics.count
        }
        return updatedIDs
    }

    @MainActor
    @discardableResult
    static func run(modelContainer: ModelContainer) async -> Bool {
        let result = await Task.detached(priority: .utility) {
            () -> (ids: [UUID], succeeded: Bool) in
            var committedIDs: [UUID] = []
            do {
                _ = try backfill(in: ModelContext(modelContainer)) { ids in
                    committedIDs.append(contentsOf: ids)
                }
                return (committedIDs, true)
            } catch {
                Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WordCountMigration")
                    .error(
                        "Word-count backfill will retry on next launch: \(error, privacy: .public)")
                return (committedIDs, false)
            }
        }.value
        // Also invalidate after a partially saved migration; no completion flag blocks retries.
        DashboardStatsCache.shared.markStale()
        NotificationCenter.default.post(
            name: .sessionMetricsDidChange, object: result.ids,
            userInfo: [didBackfillCountsKey: true])
        return result.succeeded
    }
}
