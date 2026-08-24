import CryptoKit
import Foundation
import OSLog
import SwiftData

struct LocalAudioDeduplicationResult: Equatable, Sendable {
    let deletedFileCount: Int
    let reclaimedByteCount: Int64
}

/// One-time repair for files orphaned by older usage-sync versions. It only
/// removes an unreferenced recording when an identical, currently referenced
/// recording remains on disk and the orphan did not change while it was being
/// verified. Unique orphaned audio is deliberately preserved.
@MainActor
final class LocalAudioDeduplicationService {
    static let shared = LocalAudioDeduplicationService()

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "LocalAudioDeduplicationService"
    )
    private let completionKey = "HasCompletedLocalAudioDeduplicationV2"
    private let postUsageSyncCompletionKey = "HasCompletedLocalAudioDeduplicationV3PostUsageSync"
    private var isRunning = false
    private var pendingPostUsageSyncContainer: ModelContainer?

    private init() {}

    @discardableResult
    func runIfNeeded(modelContainer: ModelContainer) -> Task<Void, Never>? {
        guard !UserDefaults.standard.bool(forKey: completionKey), !isRunning else { return nil }
        return startRepair(
            modelContainer: modelContainer,
            completionKey: completionKey,
            phase: "startup"
        )
    }

    /// Usage sync can add a record that makes an older local file recognizable
    /// as a duplicate only after the startup repair has already taken its
    /// reference snapshot. Run one final pass after the first successful sync.
    @discardableResult
    func runAfterUsageSyncIfNeeded(modelContainer: ModelContainer) -> Task<Void, Never>? {
        guard !UserDefaults.standard.bool(forKey: postUsageSyncCompletionKey) else { return nil }
        guard !isRunning else {
            pendingPostUsageSyncContainer = modelContainer
            return nil
        }
        return startRepair(
            modelContainer: modelContainer,
            completionKey: postUsageSyncCompletionKey,
            phase: "post-usage-sync"
        )
    }

    private func startRepair(
        modelContainer: ModelContainer,
        completionKey: String,
        phase: String
    ) -> Task<Void, Never> {
        isRunning = true

        let logger = logger
        let recordingsDirectory = Self.defaultRecordingsDirectory
        return Task.detached(priority: .utility) {
            do {
                let result = try Self.removeSafeDuplicateOrphans(
                    modelContainer: modelContainer,
                    recordingsDirectory: recordingsDirectory
                )
                UserDefaults.standard.set(true, forKey: completionKey)
                logger.notice(
                    "Completed local audio deduplication phase=\(phase, privacy: .public) files=\(result.deletedFileCount, privacy: .public) bytes=\(result.reclaimedByteCount, privacy: .public)"
                )
            } catch {
                logger.error(
                    "Local audio deduplication failed phase=\(phase, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            await MainActor.run {
                let service = LocalAudioDeduplicationService.shared
                service.isRunning = false
                if let pendingContainer = service.pendingPostUsageSyncContainer {
                    service.pendingPostUsageSyncContainer = nil
                    service.runAfterUsageSyncIfNeeded(modelContainer: pendingContainer)
                }
            }
        }
    }

    nonisolated static func removeSafeDuplicateOrphans(
        modelContainer: ModelContainer,
        recordingsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> LocalAudioDeduplicationResult {
        guard fileManager.fileExists(atPath: recordingsDirectory.path) else {
            return LocalAudioDeduplicationResult(deletedFileCount: 0, reclaimedByteCount: 0)
        }

        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.propertiesToFetch = [\.audioFileURL]
        let referencedPaths: Set<String> = Set(try context.fetch(descriptor).compactMap { transcription in
            guard let value = transcription.audioFileURL else { return nil }
            let url = URL(string: value) ?? URL(fileURLWithPath: value)
            return url.standardizedFileURL.path
        })

        let propertyKeys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let files = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: Array(propertyKeys),
            options: [.skipsHiddenFiles]
        )

        struct AudioFile {
            let url: URL
            let byteCount: Int64
            let modificationDate: Date
        }

        let audioFiles: [AudioFile] = files.compactMap { url in
            guard url.pathExtension.lowercased() == "wav",
                let values = try? url.resourceValues(forKeys: propertyKeys),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let byteCount = values.fileSize,
                let modificationDate = values.contentModificationDate
            else { return nil }
            return AudioFile(
                url: url,
                byteCount: Int64(byteCount),
                modificationDate: modificationDate
            )
        }

        let referencedFiles = audioFiles.filter {
            referencedPaths.contains($0.url.standardizedFileURL.path)
        }
        let orphanCandidates = audioFiles.filter {
            !referencedPaths.contains($0.url.standardizedFileURL.path)
        }
        let candidateSizes: Set<Int64> = Set(orphanCandidates.map { $0.byteCount })

        var referencedHashesBySize: [Int64: Set<String>] = [:]
        for file in referencedFiles where candidateSizes.contains(file.byteCount) {
            referencedHashesBySize[file.byteCount, default: []].insert(try sha256(of: file.url))
        }

        var deletedFileCount = 0
        var reclaimedByteCount: Int64 = 0
        for file in orphanCandidates {
            guard let hashes = referencedHashesBySize[file.byteCount],
                hashes.contains(try sha256(of: file.url)),
                let currentValues = try? file.url.resourceValues(forKeys: propertyKeys),
                currentValues.isRegularFile == true,
                currentValues.isSymbolicLink != true,
                currentValues.fileSize.map(Int64.init) == file.byteCount,
                currentValues.contentModificationDate == file.modificationDate
            else { continue }

            try fileManager.removeItem(at: file.url)
            deletedFileCount += 1
            reclaimedByteCount += file.byteCount
        }

        return LocalAudioDeduplicationResult(
            deletedFileCount: deletedFileCount,
            reclaimedByteCount: reclaimedByteCount
        )
    }

    nonisolated private static var defaultRecordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk/Recordings", isDirectory: true)
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
