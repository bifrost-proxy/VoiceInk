import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("Han character counting and legacy statistics")
struct SessionWordCountMigrationTests {
    @Test(arguments: [
        ("", 0), (" \n！？…🎉👨‍👩‍👧‍👦", 0), ("中国名著", 4), ("中國名著", 4),
        ("Hello, world!", 2), ("用VoiceInk写Swift代码", 6), ("𠀀〇你好", 4),
        ("café hello", 2), ("你好，world！2026", 4),
    ])
    func countCharactersAndWords(example: (String, Int)) {
        #expect(WordCounter.count(in: example.0) == example.1)
    }

    @MainActor
    @Test func backfillPersistsAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([Transcription.self, SessionMetric.self])
        let configuration = ModelConfiguration(
            url: root.appendingPathComponent("history.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let transcription = Transcription(text: "中国名著", duration: 4)
        transcription.transcriptionStatus = "completed"
        transcription.enhancedText = "中国四大名著"
        transcription.enhancementDuration = 0.5
        let metric = makeMetric(transcription.id, count: 2)
        let orphan = makeMetric(UUID(), count: 99)
        context.insert(transcription)
        context.insert(metric)
        context.insert(orphan)
        try context.save()

        #expect(try SessionWordCountMigration.backfill(in: context) == [transcription.id])
        #expect(metric.wordCount == 6)
        #expect(metric.wordCountVersion == WordCounter.currentVersion)
        #expect(orphan.wordCount == 99)
        #expect(orphan.wordCountVersion == nil)
        #expect(try SessionWordCountMigration.backfill(in: context).isEmpty)
        let reopened = ModelContext(container)
        let loaded = try reopened.fetch(FetchDescriptor<SessionMetric>())
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.transcriptionId == transcription.id }?.wordCountVersion == 2)
        #expect(transcription.text == "中国名著")
        #expect(metric.audioDuration == 4)
    }

    @Test func missingFailedAndFutureDataArePreserved() {
        let transcription = Transcription(text: "", duration: 4)
        transcription.transcriptionStatus = "completed"
        let metric = makeMetric(transcription.id, count: 50)
        #expect(!SessionWordCountMigration.update(metric, from: transcription))
        transcription.text = "转写失败"
        transcription.transcriptionStatus = "failed"
        #expect(!SessionWordCountMigration.update(metric, from: transcription))
        transcription.transcriptionStatus = "completed"
        metric.wordCountVersion = 99
        #expect(!SessionWordCountMigration.update(metric, from: transcription))
        #expect(metric.wordCount == 50)
    }

    @MainActor
    @Test func recorderUsesFinalTextAndDoesNotDoubleCount() throws {
        let container = try ModelContainer(
            for: Transcription.self, SessionMetric.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let transcription = Transcription(text: "中国名著", duration: 4)
        transcription.transcriptionStatus = "completed"
        container.mainContext.insert(transcription)
        #expect(
            try SessionMetricRecorder.recordRecorderSession(
                transcription: transcription, model: nil,
                in: container.mainContext))
        #expect(
            try !SessionMetricRecorder.recordRecorderSession(
                transcription: transcription, model: nil,
                in: container.mainContext))
        let metric = try #require(
            container.mainContext.fetch(FetchDescriptor<SessionMetric>()).first)
        #expect(metric.wordCount == 4)
        #expect(metric.wordCountVersion == 2)
    }

    @Test func legacySyncCannotDowngradeCorrectedCounts() throws {
        let metric = makeMetric(UUID(), count: 2)
        SessionWordCountMigration.applySyncedCount(6, version: 2, to: metric)
        SessionWordCountMigration.applySyncedCount(2, version: nil, to: metric)
        #expect(metric.wordCount == 6)
        #expect(metric.wordCountVersion == 2)
        SessionWordCountMigration.applySyncedCount(8, version: 2, to: metric)
        #expect(metric.wordCount == 8)

        let legacyJSON = """
            {"id":"\(UUID().uuidString)","transcriptionId":"\(UUID().uuidString)",
             "timestamp":0,"wordCount":2,"audioDuration":4}
            """
        var payload = try JSONDecoder().decode(
            CloudUsageDataSyncService.MetricPayload.self,
            from: Data(legacyJSON.utf8))
        #expect(payload.wordCountVersion == nil)
        payload.wordCountVersion = 2
        let roundTrip = try JSONDecoder().decode(
            CloudUsageDataSyncService.MetricPayload.self,
            from: JSONEncoder().encode(payload))
        #expect(roundTrip.wordCountVersion == 2)
    }

    @MainActor
    @Test func interruptedBackfillReportsCommittedPageAndRetriesRemainingRows() throws {
        let container = try ModelContainer(
            for: Transcription.self, SessionMetric.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for _ in 0..<501 {
            let transcription = Transcription(text: "中国四大名著", duration: 4)
            transcription.transcriptionStatus = "completed"
            context.insert(transcription)
            context.insert(makeMetric(transcription.id, count: 2))
        }
        try context.save()
        var committedIDs: [UUID] = []
        do {
            _ = try SessionWordCountMigration.backfill(in: context) { ids in
                committedIDs.append(contentsOf: ids)
                throw NSError(domain: "InterruptedAfterCommittedPage", code: 1)
            }
            Issue.record("Expected the backfill to stop after the first committed page")
        } catch {
            #expect((error as NSError).domain == "InterruptedAfterCommittedPage")
        }
        #expect(Set(committedIDs).count == 500)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<SessionMetric>())
        #expect(persisted.filter { $0.wordCountVersion == 2 && $0.wordCount == 6 }.count == 500)
        let remainingIDs = try SessionWordCountMigration.backfill(in: context)
        #expect(remainingIDs.count == 1)
        #expect(Set(committedIDs).isDisjoint(with: remainingIDs))
        #expect(try SessionWordCountMigration.backfill(in: context).isEmpty)
    }

    @Test func changedTextRecountsCurrentVersionButPreservesFutureCounts() {
        let transcription = Transcription(text: "中国名著", duration: 4)
        transcription.transcriptionStatus = "completed"
        let metric = makeMetric(transcription.id, count: 2)
        #expect(SessionWordCountMigration.update(metric, from: transcription))
        transcription.enhancedText = "中国四大名著"
        transcription.enhancementDuration = 0.5
        #expect(!SessionWordCountMigration.update(metric, from: transcription))
        #expect(SessionWordCountMigration.update(metric, from: transcription, recountCurrentVersion: true))
        #expect(metric.wordCount == 6)
        #expect(!SessionWordCountMigration.update(metric, from: transcription, recountCurrentVersion: true))
        metric.wordCountVersion = 99
        transcription.enhancedText = "中国"
        #expect(!SessionWordCountMigration.update(metric, from: transcription, recountCurrentVersion: true))
        #expect(metric.wordCount == 6)
    }

    private func makeMetric(_ id: UUID, count: Int) -> SessionMetric {
        SessionMetric(
            transcriptionId: id, wordCount: count, audioDuration: 4,
            transcriptionModelName: nil, transcriptionDuration: nil, speedFactor: nil,
            modeName: nil, aiEnhancementModelName: nil, enhancementDuration: nil)
    }
}
