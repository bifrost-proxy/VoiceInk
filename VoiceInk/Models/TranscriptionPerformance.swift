import Foundation

/// Persisted timings and transport counters for one transcription lifecycle.
/// Values stay optional so older records and non-streaming providers never
/// acquire measurements that were not actually observed.
struct TranscriptionPerformanceSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int = currentSchemaVersion
    var executionMode: String
    var streamingResolution: String?
    var connectionDuration: TimeInterval?
    var firstPartialLatency: TimeInterval?
    var firstCommitLatency: TimeInterval?
    var drainDuration: TimeInterval?
    var finalizationDuration: TimeInterval?
    var fallbackDuration: TimeInterval?
    var fallbackError: String?
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
    var transportSendFailures: Int?
    var transportFailedBytes: Int?
    var terminalReceiveError: String?
    var sessionID: String?
    var attemptID: String?
    var firstAudioAt: Date?
    var firstServerEventAt: Date?
    var lastServerEventAt: Date?
    var commitSentAt: Date?
    var maxBacklogBytes: Int?
    var maxBacklogDuration: TimeInterval?
    var maxPacketSendDuration: TimeInterval?
    var terminationReason: String?
    var recoveryStrategy: String?
    var cancelToSocketCloseDuration: TimeInterval?
    var concurrentAttemptCount: Int?
    var captureDroppedBuffers: UInt64?
    var captureDroppedFrames: UInt64?
    var captureInputFrames: UInt64?
    var captureOutputFrames: UInt64?
    var captureInputSampleRate: Double?

    init(executionMode: String) {
        self.executionMode = executionMode
    }

    mutating func recordCaptureIntegrity(_ snapshot: AudioCaptureIntegritySnapshot?) {
        guard let snapshot else { return }
        captureDroppedBuffers = snapshot.droppedBuffers
        captureDroppedFrames = snapshot.droppedFrames
        captureInputFrames = snapshot.inputFrames
        captureOutputFrames = snapshot.outputFrames
        captureInputSampleRate = snapshot.inputSampleRate > 0 ? snapshot.inputSampleRate : nil
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
