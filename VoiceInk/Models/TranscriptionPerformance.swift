import Foundation

/// Persisted timings and transport counters for one transcription lifecycle.
/// Values stay optional so older records and non-streaming providers never
/// acquire measurements that were not actually observed.
struct TranscriptionPerformanceSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var executionMode: String
    var streamingResolution: String?
    var connectionDuration: TimeInterval?
    var firstPartialLatency: TimeInterval?
    var firstCommitLatency: TimeInterval?
    var drainDuration: TimeInterval?
    var finalizationDuration: TimeInterval?
    var fallbackDuration: TimeInterval?
    var transcriptionDuration: TimeInterval?
    var postProcessingDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var deliveryDuration: TimeInterval?
    var totalProcessingDuration: TimeInterval?
    var receivedChunks: Int?
    var receivedBytes: Int?
    var sentChunks: Int?
    var sentBytes: Int?
    var droppedChunks: Int?
    var droppedBytes: Int?

    init(executionMode: String) {
        self.executionMode = executionMode
    }
}

extension Transcription {
    var performanceSnapshot: TranscriptionPerformanceSnapshot? {
        get {
            guard let performanceData else { return nil }
            return try? JSONDecoder().decode(TranscriptionPerformanceSnapshot.self, from: performanceData)
        }
        set {
            guard let newValue else {
                performanceData = nil
                return
            }
            performanceData = try? JSONEncoder().encode(newValue)
        }
    }
}
