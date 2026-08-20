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
    let authorDeviceName: String?
    let authorSequence: UInt64
    let versionClock: [String: UInt64]
    let createdAt: Date
    let payload: Data
    let payloadSHA256: String

    init(
        operationID: UUID = UUID(),
        domain: VoiceInkSyncDomain,
        authorDeviceID: String,
        authorDeviceName: String? = nil,
        authorSequence: UInt64,
        versionClock: [String: UInt64],
        createdAt: Date = Date(),
        payload: Data
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.operationID = operationID
        self.domain = domain
        self.authorDeviceID = authorDeviceID
        self.authorDeviceName = authorDeviceName
        self.authorSequence = authorSequence
        self.versionClock = versionClock
        self.createdAt = createdAt
        self.payload = payload
        self.payloadSHA256 = Self.sha256(payload)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, operationID, domain, authorDeviceID, authorDeviceName
        case authorSequence, versionClock, createdAt, payload, payloadSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        operationID = try container.decode(UUID.self, forKey: .operationID)
        domain = try container.decode(VoiceInkSyncDomain.self, forKey: .domain)
        authorDeviceID = try container.decode(String.self, forKey: .authorDeviceID)
        authorDeviceName = try container.decodeIfPresent(String.self, forKey: .authorDeviceName)
        authorSequence = try container.decode(UInt64.self, forKey: .authorSequence)
        versionClock = try container.decode([String: UInt64].self, forKey: .versionClock)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        payload = try container.decode(Data.self, forKey: .payload)
        payloadSHA256 = try container.decode(String.self, forKey: .payloadSHA256)
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

    var authorDisplayName: String {
        if let name = authorDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        {
            return name
        }
        return String(authorDeviceID.prefix(8))
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

struct VoiceInkSyncOperationMetadata: Codable, Equatable, Sendable {
    let operationID: UUID
    let authorDeviceID: String
    let authorDeviceName: String?
    let authorSequence: UInt64
    let createdAt: Date

    init(envelope: VoiceInkSyncEnvelope) {
        operationID = envelope.operationID
        authorDeviceID = envelope.authorDeviceID
        authorDeviceName = envelope.authorDeviceName
        authorSequence = envelope.authorSequence
        createdAt = envelope.createdAt
    }

    var authorDisplayName: String {
        if let name = authorDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        {
            return name
        }
        return String(authorDeviceID.prefix(8))
    }
}

struct VoiceInkSyncCandidate: Codable, Equatable, Sendable {
    let envelope: VoiceInkSyncOperationMetadata
    let mutation: VoiceInkSyncMutation
}

struct VoiceInkSyncRegisterState: Codable, Equatable, Sendable {
    private(set) var candidatesByKey: [String: [VoiceInkSyncCandidate]] = [:]
    private(set) var supersededOperationIDsByKey: [String: Set<UUID>] = [:]

    @discardableResult
    mutating func apply(_ envelope: VoiceInkSyncEnvelope, batch: VoiceInkSyncMutationBatch) -> Set<String> {
        let metadata = VoiceInkSyncOperationMetadata(envelope: envelope)
        var affectedKeys = Set<String>()
        for mutation in batch.mutations {
            guard !mutation.key.isEmpty else { continue }
            affectedKeys.insert(mutation.key)
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

            let candidate = VoiceInkSyncCandidate(envelope: metadata, mutation: mutation)
            candidates.append(candidate)
            candidates.sort(by: Self.candidatePrecedes)
            candidatesByKey[mutation.key] = candidates
        }
        return affectedKeys
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

    func latestRemoteEnvelope(
        excludingDeviceID localDeviceID: String,
        knownOperationIDs: Set<UUID>
    ) -> VoiceInkSyncOperationMetadata? {
        var envelopesByID: [UUID: VoiceInkSyncOperationMetadata] = [:]
        for candidates in candidatesByKey.values {
            for candidate in candidates {
                let envelope = candidate.envelope
                guard envelope.authorDeviceID != localDeviceID,
                    !knownOperationIDs.contains(envelope.operationID)
                else { continue }
                envelopesByID[envelope.operationID] = envelope
            }
        }
        return envelopesByID.values.max { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.operationID.uuidString < rhs.operationID.uuidString
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
    private let payloadByteLimit: Int
    let deviceID: String
    let deviceName: String
    private(set) var frontierWriteCountForTesting = 0
    private(set) var registerCheckpointWriteCountForTesting = 0
    private(set) var decodedOperationCountForTesting = 0
    private var registerCheckpoints: [VoiceInkSyncDomain: RegisterCheckpoint] = [:]

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDriveRootURL: URL? = nil,
        deviceName: String? = nil,
        payloadByteLimit: Int = ICloudDriveSyncCore.maximumPayloadBytes
    ) {
        precondition(payloadByteLimit > 0)
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDriveRootOverride = iCloudDriveRootURL
        self.payloadByteLimit = payloadByteLimit
        if let existing = defaults.string(forKey: Self.deviceIDKey), UUID(uuidString: existing) != nil {
            self.deviceID = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: Self.deviceIDKey)
            self.deviceID = created
        }
        let normalizedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = normalizedName?.isEmpty == false
            ? normalizedName!
            : Host.current().localizedName ?? "Mac"
        self.deviceName = String(resolvedName.prefix(120))
        if iCloudDriveRootURL == nil {
            pruneOrphanedSyncCaches()
        }
    }

    var rootURL: URL? {
        iCloudDriveRootURL?.appendingPathComponent("VoiceInk/Sync/v3", isDirectory: true)
    }

    func append(_ batch: VoiceInkSyncMutationBatch, domain: VoiceInkSyncDomain) throws -> VoiceInkSyncEnvelope {
        let payload = try PropertyListEncoder.voiceInkSync.encode(batch)
        guard payload.count <= payloadByteLimit else { throw POSIXError(.EFBIG) }
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
            authorDeviceName: deviceName,
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

        func encodedSize(_ candidate: ArraySlice<VoiceInkSyncMutation>) throws -> Int {
            try PropertyListEncoder.voiceInkSync.encode(
                VoiceInkSyncMutationBatch(mutations: Array(candidate))
            ).count
        }

        var start = mutations.startIndex
        while start < mutations.endIndex {
            guard try encodedSize(mutations[start...start]) <= payloadByteLimit else {
                throw POSIXError(.EFBIG)
            }

            // Find the largest deterministic prefix that fits. Encoding the growing
            // batch after every mutation is quadratic for a large first migration.
            var lowerBound = start + 1
            var upperBound = mutations.endIndex
            var bestEnd = lowerBound
            while lowerBound <= upperBound {
                let candidateEnd = lowerBound + (upperBound - lowerBound) / 2
                let fits = try encodedSize(mutations[start..<candidateEnd]) <= payloadByteLimit
                if fits {
                    bestEnd = candidateEnd
                    lowerBound = candidateEnd + 1
                } else {
                    upperBound = candidateEnd - 1
                }
            }

            let batch = Array(mutations[start..<bestEnd])
            let envelope = try append(
                VoiceInkSyncMutationBatch(mutations: batch),
                domain: domain
            )
            results.append((envelope, batch))
            start = bestEnd
        }
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
            mergeIntoFrontier(envelopes)
        }
        return envelopes
    }

    struct IncrementalReadResult: Sendable {
        let register: VoiceInkSyncRegisterState
        let affectedKeys: Set<String>
        let newEnvelopes: [VoiceInkSyncEnvelope]
        let performedFullScan: Bool
    }

    /// Loads the materialized register and applies only operation files that were not
    /// present in the last local checkpoint. Metadata events pass exact operation URLs;
    /// startup and periodic reconciliation use a full directory scan as a repair path.
    func readIncrementally(
        in domain: VoiceInkSyncDomain,
        hintedOperationURLs: Set<URL> = [],
        fullScan: Bool
    ) throws -> IncrementalReadResult {
        var checkpoint = loadRegisterCheckpoint(for: domain)
        let mustScanAll = fullScan || checkpoint == nil
        if checkpoint == nil {
            checkpoint = RegisterCheckpoint(domain: domain)
        }
        guard var checkpoint else {
            throw CocoaError(.fileReadUnknown)
        }

        let candidateURLs: [URL]
        if mustScanAll {
            candidateURLs = try operationURLs(in: domain)
        } else {
            candidateURLs = hintedOperationURLs.filter {
                operationLocation(for: $0)?.domain == domain
            }.sorted { $0.path < $1.path }
        }

        var affectedKeys = Set<String>()
        var newEnvelopes: [VoiceInkSyncEnvelope] = []
        for url in candidateURLs {
            let relativePath = try relativeOperationPath(for: url, domain: domain)
            // Operation paths are immutable and include their UUID. Once reduced into the
            // checkpoint, a File Provider metadata refresh must not make us reopen the payload.
            if checkpoint.operationFiles[relativePath] != nil { continue }
            let stamp = try operationFileStamp(at: url)
            let envelope = try readEnvelope(at: url, domain: domain)
            affectedKeys.formUnion(
                checkpoint.register.apply(envelope, batch: try decodeBatch(from: envelope)))
            checkpoint.operationFiles[relativePath] = stamp
            newEnvelopes.append(envelope)
        }

        // The operation log is append-only. Keep already materialized entries when iCloud
        // temporarily omits an item from a directory enumeration; deletions are represented by
        // tombstone operations, never by removing immutable operation files.

        if !newEnvelopes.isEmpty || loadRegisterCheckpoint(for: domain) == nil {
            saveRegisterCheckpoint(checkpoint, for: domain)
        }
        mergeIntoFrontier(newEnvelopes)
        return IncrementalReadResult(
            register: checkpoint.register,
            affectedKeys: affectedKeys,
            newEnvelopes: newEnvelopes,
            performedFullScan: mustScanAll
        )
    }

    /// Commits the already-reduced register after locally appended immutable operations.
    /// If no checkpoint exists yet, the next read performs the authoritative full rebuild.
    func updateIncrementalCheckpoint(
        register: VoiceInkSyncRegisterState,
        incorporating envelopes: [VoiceInkSyncEnvelope],
        domain: VoiceInkSyncDomain
    ) throws {
        guard var checkpoint = loadRegisterCheckpoint(for: domain) else { return }
        checkpoint.register = register
        for envelope in envelopes where envelope.domain == domain {
            guard let url = operationURL(
                operationID: envelope.operationID,
                domain: domain,
                authorDeviceID: envelope.authorDeviceID
            ) else { continue }
            checkpoint.operationFiles[try relativeOperationPath(for: url, domain: domain)] =
                try operationFileStamp(at: url)
        }
        saveRegisterCheckpoint(checkpoint, for: domain)
    }

    private struct OperationFileStamp: Codable, Equatable {
        let byteCount: Int64
        let modifiedAt: TimeInterval
    }

    private struct RegisterCheckpoint: Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let domain: VoiceInkSyncDomain
        var operationFiles: [String: OperationFileStamp]
        var register: VoiceInkSyncRegisterState

        init(domain: VoiceInkSyncDomain) {
            schemaVersion = Self.currentSchemaVersion
            self.domain = domain
            operationFiles = [:]
            register = VoiceInkSyncRegisterState()
        }

    }

    private func operationURLs(in domain: VoiceInkSyncDomain) throws -> [URL] {
        guard let domainURL = operationsURL(for: domain),
            fileManager.fileExists(atPath: domainURL.path)
        else { return [] }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: domainURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "syncop" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if values?.isUbiquitousItem == true,
                values?.ubiquitousItemDownloadingStatus != .current
            {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func relativeOperationPath(for url: URL, domain: VoiceInkSyncDomain) throws -> String {
        guard let domainURL = operationsURL(for: domain) else { throw CocoaError(.fileNoSuchFile) }
        let root = domainURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw CocoaError(.fileReadInvalidFileName) }
        return String(path.dropFirst(root.count))
    }

    private func operationFileStamp(at url: URL) throws -> OperationFileStamp {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else { throw CocoaError(.fileReadUnknown) }
        return OperationFileStamp(byteCount: byteCount, modifiedAt: modifiedAt)
    }

    private func readEnvelope(at url: URL, domain: VoiceInkSyncDomain) throws -> VoiceInkSyncEnvelope {
        decodedOperationCountForTesting += 1
        let data = try coordinatedRead(from: url)
        guard data.count <= Self.maximumEnvelopeBytes,
            let envelope = try? PropertyListDecoder().decode(VoiceInkSyncEnvelope.self, from: data),
            envelope.domain == domain,
            envelope.isValid
        else { throw CocoaError(.fileReadCorruptFile) }
        return envelope
    }

    private func loadRegisterCheckpoint(for domain: VoiceInkSyncDomain) -> RegisterCheckpoint? {
        if let checkpoint = registerCheckpoints[domain] { return checkpoint }
        guard let url = registerCheckpointURL(for: domain),
            let data = try? Data(contentsOf: url),
            let checkpoint = try? PropertyListDecoder().decode(RegisterCheckpoint.self, from: data),
            checkpoint.schemaVersion == RegisterCheckpoint.currentSchemaVersion,
            checkpoint.domain == domain
        else { return nil }
        registerCheckpoints[domain] = checkpoint
        return checkpoint
    }

    private func saveRegisterCheckpoint(_ checkpoint: RegisterCheckpoint, for domain: VoiceInkSyncDomain) {
        registerCheckpoints[domain] = checkpoint
        guard let url = registerCheckpointURL(for: domain),
            let data = try? PropertyListEncoder.voiceInkSync.encode(checkpoint)
        else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil {
            registerCheckpointWriteCountForTesting += 1
        }
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

    private func registerCheckpointURL(for domain: VoiceInkSyncDomain) -> URL? {
        guard let rootURL else { return nil }
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheRoot = caches.appendingPathComponent(
            "com.prakashjoshipax.VoiceInk/ICloudSyncIndex", isDirectory: true)
        let rootDigest = VoiceInkSyncEnvelope.sha256(Data(rootURL.standardizedFileURL.path.utf8))
        return cacheRoot.appendingPathComponent(
            "\(rootDigest)-\(deviceID)-\(domain.rawValue)-register-v1.plist")
    }

    private func pruneOrphanedSyncCaches() {
        guard let rootURL,
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        let cacheRoot = caches.appendingPathComponent(
            "com.prakashjoshipax.VoiceInk/ICloudSyncIndex", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let activePrefix = VoiceInkSyncEnvelope.sha256(
            Data(rootURL.standardizedFileURL.path.utf8)) + "-"
        var entries: [(url: URL, size: Int, modifiedAt: Date)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append((url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        let maximumCacheBytes = 64 * 1_024 * 1_024
        var totalBytes = entries.reduce(0) { $0 + $1.size }
        guard totalBytes > maximumCacheBytes else { return }
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt })
        where !entry.url.lastPathComponent.hasPrefix(activePrefix) {
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
            if totalBytes <= maximumCacheBytes { break }
        }
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

    struct OperationLocation: Equatable, Sendable {
        let domain: VoiceInkSyncDomain
        let authorDeviceID: String
        let operationID: UUID
    }

    func operationLocation(for url: URL) -> OperationLocation? {
        guard let operationsRoot = rootURL?.appendingPathComponent("Operations", isDirectory: true) else {
            return nil
        }
        let rootPath = operationsRoot.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath), url.pathExtension == "syncop" else { return nil }
        let components = path.dropFirst(rootPath.count).split(separator: "/")
        guard components.count == 4,
            let domain = VoiceInkSyncDomain(rawValue: String(components[0])),
            UUID(uuidString: String(components[1])) != nil,
            let operationID = UUID(uuidString: String(components[3].dropLast(".syncop".count)))
        else { return nil }
        return OperationLocation(
            domain: domain, authorDeviceID: String(components[1]), operationID: operationID)
    }

    func shouldConsumeRemoteOperation(
        at url: URL,
        domains: Set<VoiceInkSyncDomain>
    ) -> Bool {
        guard let location = operationLocation(for: url) else { return false }
        return domains.contains(location.domain) && location.authorDeviceID != deviceID
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

    func operationURL(for envelope: VoiceInkSyncEnvelope) -> URL? {
        operationURL(
            operationID: envelope.operationID,
            domain: envelope.domain,
            authorDeviceID: envelope.authorDeviceID
        )
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

        let writeData: (URL) throws -> Void = { url in
            let stagingURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(envelope.operationID.uuidString).incoming")
            defer { try? self.fileManager.removeItem(at: stagingURL) }
            try? self.fileManager.removeItem(at: stagingURL)
            try data.write(to: stagingURL, options: .atomic)
            do {
                try self.fileManager.moveItem(at: stagingURL, to: url)
            } catch {
                guard self.fileManager.fileExists(atPath: url.path),
                    try Data(contentsOf: url) == data
                else { throw error }
            }
        }

        // Injected roots are ordinary local directories used by deterministic tests.
        // Coordinating them can stall on CI when the x86_64 runner's filecoordinationd
        // service is unavailable; real iCloud Drive paths still use coordination.
        if iCloudDriveRootOverride != nil {
            try writeData(destination)
            return
        }

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { url in
            do {
                try writeData(url)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func coordinatedRead(from url: URL) throws -> Data {
        if iCloudDriveRootOverride != nil {
            return try Data(contentsOf: url)
        }

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
        mergeIntoFrontier([envelope])
    }

    private func mergeIntoFrontier(_ envelopes: [VoiceInkSyncEnvelope]) {
        var frontier = loadFrontier()
        var didChange = false
        for envelope in envelopes {
            for (device, sequence) in envelope.versionClock
                where sequence > frontier[device, default: 0]
            {
                frontier[device] = sequence
                didChange = true
            }
        }
        guard didChange else { return }
        guard let data = try? PropertyListEncoder.voiceInkSync.encode(frontier) else { return }
        frontierWriteCountForTesting += 1
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
