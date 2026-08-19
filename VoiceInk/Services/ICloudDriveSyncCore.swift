import CryptoKit
import Foundation

enum VoiceInkSyncDomain: String, Codable, CaseIterable, Sendable {
    case configuration
    case dictionary
    case usage
}

struct VoiceInkSyncEnvelope: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 3

    let protocolVersion: Int
    let operationID: UUID
    let domain: VoiceInkSyncDomain
    let authorDeviceID: String
    let authorSequence: UInt64
    let versionClock: [String: UInt64]
    let createdAt: Date
    let payload: Data
    let payloadSHA256: String

    init(
        operationID: UUID = UUID(),
        domain: VoiceInkSyncDomain,
        authorDeviceID: String,
        authorSequence: UInt64,
        versionClock: [String: UInt64],
        createdAt: Date = Date(),
        payload: Data
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.operationID = operationID
        self.domain = domain
        self.authorDeviceID = authorDeviceID
        self.authorSequence = authorSequence
        self.versionClock = versionClock
        self.createdAt = createdAt
        self.payload = payload
        self.payloadSHA256 = Self.sha256(payload)
    }

    var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && UUID(uuidString: authorDeviceID) != nil
            && authorSequence > 0
            && versionClock.count <= 10_000
            && versionClock.values.allSatisfy { $0 > 0 }
            && versionClock[authorDeviceID] == authorSequence
            && payloadSHA256 == Self.sha256(payload)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct VoiceInkSyncMutation: Codable, Equatable, Sendable {
    let key: String
    let value: Data?
    let supersededOperationIDs: [UUID]

    init(key: String, value: Data?, supersededOperationIDs: [UUID] = []) {
        self.key = key
        self.value = value
        self.supersededOperationIDs = Array(Set(supersededOperationIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key, value, supersededOperationIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decodeIfPresent(Data.self, forKey: .value)
        supersededOperationIDs =
            try container.decodeIfPresent([UUID].self, forKey: .supersededOperationIDs) ?? []
    }
}

struct VoiceInkSyncMutationBatch: Codable, Equatable, Sendable {
    let mutations: [VoiceInkSyncMutation]
}

struct VoiceInkSyncCandidate: Equatable, Sendable {
    let envelope: VoiceInkSyncEnvelope
    let mutation: VoiceInkSyncMutation
}

struct VoiceInkSyncRegisterState: Equatable, Sendable {
    private(set) var candidatesByKey: [String: [VoiceInkSyncCandidate]] = [:]
    private(set) var supersededOperationIDsByKey: [String: Set<UUID>] = [:]

    mutating func apply(_ envelope: VoiceInkSyncEnvelope, batch: VoiceInkSyncMutationBatch) {
        for mutation in batch.mutations {
            guard !mutation.key.isEmpty else { continue }
            var superseded = supersededOperationIDsByKey[mutation.key, default: []]
            superseded.formUnion(mutation.supersededOperationIDs)
            supersededOperationIDsByKey[mutation.key] = superseded

            var candidates = candidatesByKey[mutation.key, default: []]
            candidates.removeAll { superseded.contains($0.envelope.operationID) }
            guard !superseded.contains(envelope.operationID),
                !candidates.contains(where: { $0.envelope.operationID == envelope.operationID })
            else {
                candidatesByKey[mutation.key] = candidates
                continue
            }

            let candidate = VoiceInkSyncCandidate(envelope: envelope, mutation: mutation)
            candidates.append(candidate)
            candidates.sort(by: Self.candidatePrecedes)
            candidatesByKey[mutation.key] = candidates
        }
    }

    func operationIDs(for key: String) -> [UUID] {
        (candidatesByKey[key] ?? []).map(\.envelope.operationID)
    }

    func selectedCandidate(
        for key: String,
        addWins: Bool = false,
        deleteWins: Bool = false
    ) -> VoiceInkSyncCandidate? {
        guard let candidates = candidatesByKey[key], !candidates.isEmpty else { return nil }
        let eligible: [VoiceInkSyncCandidate]
        if deleteWins, candidates.contains(where: { $0.mutation.value == nil }) {
            eligible = candidates.filter { $0.mutation.value == nil }
        } else if addWins, candidates.contains(where: { $0.mutation.value != nil }) {
            eligible = candidates.filter { $0.mutation.value != nil }
        } else {
            eligible = candidates
        }
        return eligible.max(by: Self.candidatePrecedes)
    }

    func selectedValues(addWins: Bool = false, deleteWins: Bool = false) -> [String: Data] {
        candidatesByKey.reduce(into: [:]) { result, element in
            if let value = selectedCandidate(
                for: element.key, addWins: addWins, deleteWins: deleteWins
            )?.mutation.value {
                result[element.key] = value
            }
        }
    }

    var conflictCount: Int {
        candidatesByKey.values.reduce(into: 0) { count, candidates in
            let distinct = Set(candidates.map { $0.mutation.value })
            if distinct.count > 1 { count += 1 }
        }
    }

    private static func candidatePrecedes(_ lhs: VoiceInkSyncCandidate, _ rhs: VoiceInkSyncCandidate) -> Bool {
        if lhs.envelope.authorDeviceID != rhs.envelope.authorDeviceID {
            return lhs.envelope.authorDeviceID < rhs.envelope.authorDeviceID
        }
        if lhs.envelope.authorSequence != rhs.envelope.authorSequence {
            return lhs.envelope.authorSequence < rhs.envelope.authorSequence
        }
        return lhs.envelope.operationID.uuidString < rhs.envelope.operationID.uuidString
    }
}

/// Shared append-only transport for every VoiceInk iCloud Drive sync domain.
/// iCloud Drive copies immutable operation files; domain reducers own merge semantics.
final class ICloudDriveSyncCore: @unchecked Sendable {
    static let shared = ICloudDriveSyncCore()
    static let maximumPayloadBytes = 7 * 1_024 * 1_024
    private static let maximumEnvelopeBytes = 8 * 1_024 * 1_024

    private static let metadataPrefix = "VoiceInkSyncV3."
    private static let deviceIDKey = metadataPrefix + "deviceID"
    private static let sequenceKey = metadataPrefix + "sequence"
    private static let frontierKey = metadataPrefix + "frontier"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let iCloudDriveRootOverride: URL?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDriveRootURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDriveRootOverride = iCloudDriveRootURL
    }

    var rootURL: URL? {
        iCloudDriveRootURL?.appendingPathComponent("VoiceInk/Sync/v3", isDirectory: true)
    }

    var deviceID: String {
        if let existing = defaults.string(forKey: Self.deviceIDKey), UUID(uuidString: existing) != nil {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: Self.deviceIDKey)
        return created
    }

    func append(_ batch: VoiceInkSyncMutationBatch, domain: VoiceInkSyncDomain) throws -> VoiceInkSyncEnvelope {
        let payload = try PropertyListEncoder.voiceInkSync.encode(batch)
        guard payload.count <= Self.maximumPayloadBytes else { throw POSIXError(.EFBIG) }
        let operationID = retryStableOperationID(domain: domain, payload: payload)
        if let existing = try existingEnvelope(
            operationID: operationID,
            domain: domain,
            payload: payload
        ) {
            mergeIntoFrontier(existing)
            return existing
        }
        let sequence = nextSequence()
        var clock = loadFrontier()
        clock[deviceID] = sequence
        let envelope = VoiceInkSyncEnvelope(
            operationID: operationID,
            domain: domain,
            authorDeviceID: deviceID,
            authorSequence: sequence,
            versionClock: clock,
            payload: payload
        )
        try write(envelope)
        mergeIntoFrontier(envelope)
        return envelope
    }

    /// Splits a logical mutation set into independently valid immutable files.
    /// This keeps a large dictionary import or a record with many metrics from
    /// wedging every later sync behind the per-file safety limit.
    func appendChunked(
        _ mutations: [VoiceInkSyncMutation],
        domain: VoiceInkSyncDomain
    ) throws -> [(envelope: VoiceInkSyncEnvelope, mutations: [VoiceInkSyncMutation])] {
        var results: [(VoiceInkSyncEnvelope, [VoiceInkSyncMutation])] = []
        var batch: [VoiceInkSyncMutation] = []

        func encodedSize(_ candidate: [VoiceInkSyncMutation]) throws -> Int {
            try PropertyListEncoder.voiceInkSync.encode(
                VoiceInkSyncMutationBatch(mutations: candidate)
            ).count
        }

        func flush() throws {
            guard !batch.isEmpty else { return }
            let mutations = batch
            let envelope = try append(
                VoiceInkSyncMutationBatch(mutations: mutations),
                domain: domain
            )
            results.append((envelope, mutations))
            batch.removeAll(keepingCapacity: true)
        }

        for mutation in mutations {
            let candidate = batch + [mutation]
            if try encodedSize(candidate) <= Self.maximumPayloadBytes {
                batch = candidate
                continue
            }

            guard !batch.isEmpty else { throw POSIXError(.EFBIG) }
            try flush()
            guard try encodedSize([mutation]) <= Self.maximumPayloadBytes else {
                throw POSIXError(.EFBIG)
            }
            batch = [mutation]
        }
        try flush()
        return results
    }

    private func retryStableOperationID(domain: VoiceInkSyncDomain, payload: Data) -> UUID {
        var material = Data(domain.rawValue.utf8)
        material.append(0)
        material.append(contentsOf: deviceID.utf8)
        material.append(0)
        material.append(payload)
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func existingEnvelope(
        operationID: UUID,
        domain: VoiceInkSyncDomain,
        payload: Data
    ) throws -> VoiceInkSyncEnvelope? {
        guard let destination = operationURL(
            operationID: operationID,
            domain: domain,
            authorDeviceID: deviceID
        ), fileManager.fileExists(atPath: destination.path) else { return nil }
        let values = try? destination.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
            try? fileManager.startDownloadingUbiquitousItem(at: destination)
            throw CocoaError(.fileReadNoSuchFile)
        }
        let data = try coordinatedRead(from: destination)
        guard data.count <= Self.maximumEnvelopeBytes,
            let envelope = try? PropertyListDecoder().decode(VoiceInkSyncEnvelope.self, from: data),
            envelope.isValid,
            envelope.operationID == operationID,
            envelope.domain == domain,
            envelope.authorDeviceID == deviceID,
            envelope.payload == payload
        else { throw CocoaError(.fileReadCorruptFile) }
        return envelope
    }

    func readAll(
        in domain: VoiceInkSyncDomain,
        mergeIntoLocalFrontier: Bool = true
    ) throws -> [VoiceInkSyncEnvelope] {
        guard let domainURL = operationsURL(for: domain) else { return [] }
        guard fileManager.fileExists(atPath: domainURL.path) else { return [] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = fileManager.enumerator(
            at: domainURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var envelopes: [VoiceInkSyncEnvelope] = []
        var envelopesByOperationID: [UUID: VoiceInkSyncEnvelope] = [:]
        var cached = loadIndex(for: domain)
        var refreshed: [String: CachedEnvelope] = [:]
        var hasPendingDownload = false
        for case let url as URL in enumerator where url.pathExtension == "syncop" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                hasPendingDownload = true
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let relativePath = String(url.path.dropFirst(domainURL.path.count))
            let envelope: VoiceInkSyncEnvelope
            if let entry = cached.removeValue(forKey: relativePath),
                entry.byteCount == byteCount, entry.modifiedAt == modifiedAt,
                entry.envelope.domain == domain, entry.envelope.isValid
            {
                envelope = entry.envelope
            } else {
                let data = try coordinatedRead(from: url)
                guard data.count <= Self.maximumEnvelopeBytes,
                    let decoded = try? PropertyListDecoder().decode(VoiceInkSyncEnvelope.self, from: data),
                    decoded.domain == domain, decoded.isValid
                else { throw CocoaError(.fileReadCorruptFile) }
                envelope = decoded
            }
            refreshed[relativePath] = CachedEnvelope(
                byteCount: byteCount, modifiedAt: modifiedAt, envelope: envelope)
            if let existing = envelopesByOperationID[envelope.operationID] {
                guard existing == envelope else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                continue
            }
            envelopesByOperationID[envelope.operationID] = envelope
            envelopes.append(envelope)
        }
        if hasPendingDownload { throw CocoaError(.fileReadNoSuchFile) }
        saveIndex(refreshed, for: domain)
        envelopes.sort { lhs, rhs in
            if lhs.authorDeviceID != rhs.authorDeviceID { return lhs.authorDeviceID < rhs.authorDeviceID }
            if lhs.authorSequence != rhs.authorSequence { return lhs.authorSequence < rhs.authorSequence }
            return lhs.operationID.uuidString < rhs.operationID.uuidString
        }
        if mergeIntoLocalFrontier {
            for envelope in envelopes { mergeIntoFrontier(envelope) }
        }
        return envelopes
    }

    private struct CachedEnvelope: Codable {
        let byteCount: Int64
        let modifiedAt: TimeInterval
        let envelope: VoiceInkSyncEnvelope
    }

    private func loadIndex(for domain: VoiceInkSyncDomain) -> [String: CachedEnvelope] {
        guard let url = indexURL(for: domain),
            let data = try? Data(contentsOf: url),
            let index = try? PropertyListDecoder().decode([String: CachedEnvelope].self, from: data)
        else { return [:] }
        return index
    }

    private func saveIndex(_ index: [String: CachedEnvelope], for domain: VoiceInkSyncDomain) {
        guard let url = indexURL(for: domain),
            let data = try? PropertyListEncoder.voiceInkSync.encode(index)
        else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The operation index is a disposable local acceleration cache. It must
    /// never live in iCloud Drive or UserDefaults because payloads can be large.
    private func indexURL(for domain: VoiceInkSyncDomain) -> URL? {
        guard let rootURL else { return nil }
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheRoot = caches.appendingPathComponent(
            "com.prakashjoshipax.VoiceInk/ICloudSyncIndex", isDirectory: true)
        let rootDigest = VoiceInkSyncEnvelope.sha256(Data(rootURL.standardizedFileURL.path.utf8))
        return cacheRoot.appendingPathComponent("\(rootDigest)-\(domain.rawValue).plist")
    }

    func decodeBatch(from envelope: VoiceInkSyncEnvelope) throws -> VoiceInkSyncMutationBatch {
        let batch = try PropertyListDecoder().decode(VoiceInkSyncMutationBatch.self, from: envelope.payload)
        guard batch.mutations.count <= 50_000,
            batch.mutations.allSatisfy({
                !$0.key.isEmpty && $0.key.utf8.count <= 1_024
                    && $0.supersededOperationIDs.count <= 50_000
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        return batch
    }

    private var iCloudDriveRootURL: URL? {
        if let iCloudDriveRootOverride { return iCloudDriveRootOverride }
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return root
    }

    private func operationsURL(for domain: VoiceInkSyncDomain) -> URL? {
        rootURL?.appendingPathComponent("Operations/\(domain.rawValue)", isDirectory: true)
    }

    private func operationURL(
        operationID: UUID,
        domain: VoiceInkSyncDomain,
        authorDeviceID: String
    ) -> URL? {
        let shard = String(operationID.uuidString.prefix(2)).lowercased()
        return operationsURL(for: domain)?
            .appendingPathComponent(authorDeviceID, isDirectory: true)
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(operationID.uuidString + ".syncop")
    }

    private func write(_ envelope: VoiceInkSyncEnvelope) throws {
        guard let destination = operationURL(
            operationID: envelope.operationID,
            domain: envelope.domain,
            authorDeviceID: envelope.authorDeviceID
        ) else { throw CocoaError(.fileNoSuchFile) }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListEncoder.voiceInkSync.encode(envelope)
        guard data.count <= Self.maximumEnvelopeBytes else { throw POSIXError(.EFBIG) }

        if fileManager.fileExists(atPath: destination.path) {
            let existing = try coordinatedRead(from: destination)
            guard existing == data else { throw CocoaError(.fileWriteFileExists) }
            return
        }

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { url in
            let stagingURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(envelope.operationID.uuidString).incoming")
            defer { try? self.fileManager.removeItem(at: stagingURL) }
            do {
                try? self.fileManager.removeItem(at: stagingURL)
                try data.write(to: stagingURL, options: .atomic)
                do {
                    try self.fileManager.moveItem(at: stagingURL, to: url)
                } catch {
                    guard self.fileManager.fileExists(atPath: url.path),
                        try Data(contentsOf: url) == data
                    else { throw error }
                }
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func coordinatedRead(from url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func nextSequence() -> UInt64 {
        let next = UInt64(max(0, defaults.integer(forKey: Self.sequenceKey))) + 1
        defaults.set(next, forKey: Self.sequenceKey)
        return next
    }

    private func loadFrontier() -> [String: UInt64] {
        guard let data = defaults.data(forKey: Self.frontierKey),
            let frontier = try? PropertyListDecoder().decode([String: UInt64].self, from: data)
        else { return [:] }
        return frontier
    }

    private func mergeIntoFrontier(_ envelope: VoiceInkSyncEnvelope) {
        var frontier = loadFrontier()
        for (device, sequence) in envelope.versionClock {
            frontier[device] = max(frontier[device, default: 0], sequence)
        }
        guard let data = try? PropertyListEncoder.voiceInkSync.encode(frontier) else { return }
        defaults.set(data, forKey: Self.frontierKey)
    }
}

extension PropertyListEncoder {
    fileprivate static var voiceInkSync: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
