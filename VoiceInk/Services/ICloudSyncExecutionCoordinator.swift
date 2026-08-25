import Foundation

/// Runs every iCloud Drive synchronization batch on one utility queue.
///
/// File coordination and FileProvider reads are intentionally synchronous once
/// a batch starts, so putting them on a dedicated serial queue keeps them away
/// from the main actor and prevents configuration, dictionary, and usage sync
/// from competing with each other for disk and iCloud resources.
final class ICloudSyncExecutionCoordinator: @unchecked Sendable {
    static let shared = ICloudSyncExecutionCoordinator()

    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue: DispatchQueue

    init(label: String = "com.prakashjoshipax.voiceink.icloud-sync") {
        queue = DispatchQueue(label: label, qos: .utility, autoreleaseFrequency: .workItem)
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    func run<Value>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    static var isExecutingOnSyncQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }
}

enum ICloudSyncRetryPolicy {
    private static let delays: [TimeInterval] = [5, 15, 30, 60, 300]
    private static let pendingDownloadDelays: [TimeInterval] = [1, 2, 5, 10, 30]

    static func baseDelay(afterFailureCount failureCount: Int) -> TimeInterval {
        delays[min(max(failureCount - 1, 0), delays.count - 1)]
    }

    static func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        baseDelay(afterFailureCount: failureCount) * Double.random(in: 0.85...1.15)
    }

    static func basePendingDownloadDelay(afterFailureCount failureCount: Int) -> TimeInterval {
        pendingDownloadDelays[min(max(failureCount - 1, 0), pendingDownloadDelays.count - 1)]
    }

    static func pendingDownloadDelay(afterFailureCount failureCount: Int) -> TimeInterval {
        basePendingDownloadDelay(afterFailureCount: failureCount) * Double.random(in: 0.85...1.15)
    }

    static func isPendingICloudDownload(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}
