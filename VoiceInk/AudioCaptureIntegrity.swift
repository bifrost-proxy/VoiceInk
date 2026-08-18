import Foundation

/// End-to-end counters for one hardware capture lifecycle. A non-zero drop
/// count means both the streaming path and the recorded WAV are incomplete.
struct AudioCaptureIntegritySnapshot: Equatable, Sendable {
    var droppedBackpressureBuffers: UInt64 = 0
    var droppedCapacityBuffers: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputSampleRate: Double = 0

    static let empty = AudioCaptureIntegritySnapshot()

    var droppedBuffers: UInt64 {
        droppedBackpressureBuffers + droppedCapacityBuffers
    }

    var hasCaptureLoss: Bool {
        droppedBuffers > 0 || droppedFrames > 0
    }
}
