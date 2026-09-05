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
    static func update(_ metric: SessionMetric, from transcription: Transcription) -> Bool {
        guard (metric.wordCountVersion ?? 1) < WordCounter.currentVersion,
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
        metric.wordCount = WordCounter.count(in: text)
        metric.wordCountVersion = WordCounter.currentVersion
        return true
    }

    static func backfill(in context: ModelContext) throws -> [UUID] {
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
            var changed = false
            for metric in metrics where (metric.wordCountVersion ?? 1) < WordCounter.currentVersion
            {
                let id = metric.transcriptionId
                var transcriptionDescriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate { $0.id == id && $0.transcriptionStatus == "completed" })
                transcriptionDescriptor.fetchLimit = 1
                if let transcription = try context.fetch(transcriptionDescriptor).first,
                    update(metric, from: transcription)
                {
                    updatedIDs.append(id)
                    changed = true
                }
            }
            if changed { try context.save() }
            offset += metrics.count
        }
        return updatedIDs
    }

    @MainActor
    static func run(modelContainer: ModelContainer) async -> Bool {
        let result = await Task.detached(priority: .utility) {
            () -> (ids: [UUID], succeeded: Bool) in
            do {
                return (try backfill(in: ModelContext(modelContainer)), true)
            } catch {
                Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WordCountMigration")
                    .error(
                        "Word-count backfill will retry on next launch: \(error, privacy: .public)")
                return ([], false)
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
