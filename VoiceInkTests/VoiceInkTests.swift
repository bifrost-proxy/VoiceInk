//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
import SwiftData
import Testing
@testable import VoiceInk

private final class ICloudSyncConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var blockerStarted = false

    func enter() {
        lock.withLock {
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
        }
    }

    func leave() {
        lock.withLock { activeCount -= 1 }
    }

    func markBlockerStarted() {
        lock.withLock { blockerStarted = true }
    }

    var maximumActive: Int { lock.withLock { maximumActiveCount } }
    var hasBlockerStarted: Bool { lock.withLock { blockerStarted } }
}

private final class DownloadRequestRecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    override func startDownloadingUbiquitousItem(at url: URL) throws {
        lock.withLock { recordedURLs.append(url.standardizedFileURL) }
    }

    var downloadRequests: [URL] { lock.withLock { recordedURLs } }
}

struct VoiceInkTests {
    @Test func whisperPCMReaderConvertsSamplesWithoutPerSampleDataAllocations() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkWhisperSamples-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        var wav = Data(repeating: 0, count: 44)
        for sample in [Int16.min, -16_384, 0, 16_384, Int16.max] {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        try wav.write(to: url)

        let samples = try WhisperTranscriptionService.readAudioSamples(url)
        #expect(samples.count == 5)
        #expect(samples[0] == -1)
        #expect(abs(samples[1] + 0.500_015_26) < 0.000_001)
        #expect(samples[2] == 0)
        #expect(abs(samples[3] - 0.500_015_26) < 0.000_001)
        #expect(samples[4] == 1)
    }

    @Test func whisperPCMReaderRejectsTruncatedHeaders() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkWhisperTruncated-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 43).write(to: url)

        #expect(throws: CocoaError.self) {
            _ = try WhisperTranscriptionService.readAudioSamples(url)
        }
    }

    @Test func syncRegisterIgnoresArrivalOrderWhenAnEditSupersedesAnOlderValue() throws {
        let originalID = UUID()
        let replacementID = UUID()
        let original = try syncEnvelope(
            operationID: originalID,
            deviceID: "Mac-A",
            sequence: 1,
            mutation: VoiceInkSyncMutation(key: "preference/language", value: Data("en".utf8))
        )
        let replacement = try syncEnvelope(
            operationID: replacementID,
            deviceID: "Mac-B",
            sequence: 1,
            mutation: VoiceInkSyncMutation(
                key: "preference/language",
                value: Data("zh".utf8),
                supersededOperationIDs: [originalID]
            )
        )

        var register = VoiceInkSyncRegisterState()
        register.apply(replacement.envelope, batch: replacement.batch)
        register.apply(original.envelope, batch: original.batch)

        #expect(register.selectedValues()["preference/language"] == Data("zh".utf8))
        #expect(register.operationIDs(for: "preference/language") == [replacementID])
        #expect(register.conflictCount == 0)
    }

    @Test func syncRegisterPreservesOfflineConcurrentValuesUntilObservedResolution() throws {
        let firstID = UUID()
        let secondID = UUID()
        let resolutionID = UUID()
        let first = try syncEnvelope(
            operationID: firstID,
            deviceID: "Mac-A",
            sequence: 1,
            mutation: VoiceInkSyncMutation(key: "preference/language", value: Data("en".utf8))
        )
        let second = try syncEnvelope(
            operationID: secondID,
            deviceID: "Mac-B",
            sequence: 1,
            mutation: VoiceInkSyncMutation(key: "preference/language", value: Data("zh".utf8))
        )

        var register = VoiceInkSyncRegisterState()
        register.apply(first.envelope, batch: first.batch)
        register.apply(second.envelope, batch: second.batch)

        #expect(Set(register.operationIDs(for: "preference/language")) == Set([firstID, secondID]))
        #expect(register.conflictCount == 1)

        let resolution = try syncEnvelope(
            operationID: resolutionID,
            deviceID: "Mac-A",
            sequence: 2,
            mutation: VoiceInkSyncMutation(
                key: "preference/language",
                value: Data("ja".utf8),
                supersededOperationIDs: register.operationIDs(for: "preference/language")
            )
        )
        register.apply(resolution.envelope, batch: resolution.batch)

        #expect(register.selectedValues()["preference/language"] == Data("ja".utf8))
        #expect(register.operationIDs(for: "preference/language") == [resolutionID])
        #expect(register.conflictCount == 0)
    }

    @Test func syncRegisterResolutionRemainsStableWhenSupersededFilesArriveLate() throws {
        let firstID = UUID()
        let secondID = UUID()
        let resolutionID = UUID()
        let first = try syncEnvelope(
            operationID: firstID, deviceID: "Mac-A", sequence: 1,
            mutation: VoiceInkSyncMutation(key: "record/1", value: Data("first".utf8))
        )
        let second = try syncEnvelope(
            operationID: secondID, deviceID: "Mac-B", sequence: 1,
            mutation: VoiceInkSyncMutation(key: "record/1", value: Data("second".utf8))
        )
        let resolution = try syncEnvelope(
            operationID: resolutionID, deviceID: "Mac-C", sequence: 1,
            mutation: VoiceInkSyncMutation(
                key: "record/1", value: Data("resolved".utf8),
                supersededOperationIDs: [firstID, secondID]
            )
        )

        var register = VoiceInkSyncRegisterState()
        register.apply(resolution.envelope, batch: resolution.batch)
        register.apply(second.envelope, batch: second.batch)
        register.apply(first.envelope, batch: first.batch)

        #expect(register.selectedValues()["record/1"] == Data("resolved".utf8))
        #expect(register.operationIDs(for: "record/1") == [resolutionID])
    }

    @Test func dictionaryAddWinsOnlyUntilADeleteObservesEveryActiveCandidate() throws {
        let addID = UUID()
        let concurrentDeleteID = UUID()
        let observedDeleteID = UUID()
        let add = try syncEnvelope(
            operationID: addID, deviceID: "Mac-A", sequence: 1, domain: .dictionary,
            mutation: VoiceInkSyncMutation(key: "vocabulary/voiceink", value: Data("VoiceInk".utf8))
        )
        let concurrentDelete = try syncEnvelope(
            operationID: concurrentDeleteID, deviceID: "Mac-B", sequence: 1, domain: .dictionary,
            mutation: VoiceInkSyncMutation(key: "vocabulary/voiceink", value: nil)
        )

        var register = VoiceInkSyncRegisterState()
        register.apply(concurrentDelete.envelope, batch: concurrentDelete.batch)
        register.apply(add.envelope, batch: add.batch)
        #expect(register.selectedValues(addWins: true)["vocabulary/voiceink"] == Data("VoiceInk".utf8))

        let observedDelete = try syncEnvelope(
            operationID: observedDeleteID, deviceID: "Mac-B", sequence: 2, domain: .dictionary,
            mutation: VoiceInkSyncMutation(
                key: "vocabulary/voiceink", value: nil,
                supersededOperationIDs: register.operationIDs(for: "vocabulary/voiceink")
            )
        )
        register.apply(observedDelete.envelope, batch: observedDelete.batch)

        #expect(register.selectedValues(addWins: true)["vocabulary/voiceink"] == nil)
        #expect(register.operationIDs(for: "vocabulary/voiceink") == [observedDeleteID])
        #expect(register.conflictCount == 0)
    }

    @Test func usageDeleteWinsConcurrentEditWithoutDiscardingTheEditCandidate() throws {
        let editID = UUID()
        let deleteID = UUID()
        let edit = try syncEnvelope(
            operationID: editID, deviceID: "Mac-A", sequence: 1, domain: .usage,
            mutation: VoiceInkSyncMutation(key: "transcription/record", value: Data("edited".utf8))
        )
        let deletion = try syncEnvelope(
            operationID: deleteID, deviceID: "Mac-B", sequence: 1, domain: .usage,
            mutation: VoiceInkSyncMutation(key: "transcription/record", value: nil)
        )

        var register = VoiceInkSyncRegisterState()
        register.apply(edit.envelope, batch: edit.batch)
        register.apply(deletion.envelope, batch: deletion.batch)

        #expect(register.selectedValues(deleteWins: true)["transcription/record"] == nil)
        #expect(Set(register.operationIDs(for: "transcription/record")) == Set([editID, deleteID]))
        #expect(register.conflictCount == 1)
    }

    @Test func syncCoreRejectsOversizedOperationsWithoutWritingPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkOversizedSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.OversizedSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = ICloudDriveSyncCore(defaults: defaults, iCloudDriveRootURL: root)
        let payload = Data(repeating: 0x5a, count: ICloudDriveSyncCore.maximumPayloadBytes + 1)

        #expect(throws: POSIXError.self) {
            _ = try core.append(
                VoiceInkSyncMutationBatch(mutations: [
                    VoiceInkSyncMutation(key: "preference/oversized", value: payload)
                ]),
                domain: .configuration
            )
        }

        let operations = root.appendingPathComponent(
            "VoiceInk/Sync/v3/Operations/configuration", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: operations.path))
    }

    @Test func syncCoreSplitsLargeMutationSetsIntoValidImmutableOperations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkChunkedSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.ChunkedSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = ICloudDriveSyncCore(defaults: defaults, iCloudDriveRootURL: root)
        let mutations = [
            VoiceInkSyncMutation(
                key: "preference/first",
                value: Data(repeating: 0x3c, count: 4 * 1_024 * 1_024)
            ),
            VoiceInkSyncMutation(
                key: "preference/second",
                value: Data(repeating: 0x4d, count: 4 * 1_024 * 1_024)
            ),
        ]

        let written = try core.appendChunked(mutations, domain: .configuration)
        #expect(written.count == 2)
        #expect(written.flatMap { $0.mutations } == mutations)
        #expect(try core.readAll(in: .configuration).count == 2)
        for item in written {
            #expect(item.envelope.payload.count <= ICloudDriveSyncCore.maximumPayloadBytes)
        }

        let retried = try core.appendChunked(mutations, domain: .configuration)
        #expect(retried.map(\.envelope.operationID) == written.map(\.envelope.operationID))
        #expect(try core.readAll(in: .configuration).count == 2)
    }

    @Test func readingUnchangedOperationsDoesNotRewriteTheFrontier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkStableFrontier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.StableFrontier.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = ICloudDriveSyncCore(defaults: defaults, iCloudDriveRootURL: root)
        _ = try core.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/language", value: Data("en".utf8))
        ]), domain: .configuration)

        let writesAfterAppend = core.frontierWriteCountForTesting
        _ = try core.readAll(in: .configuration)
        _ = try core.readAll(in: .configuration)
        #expect(core.frontierWriteCountForTesting == writesAfterAppend)
    }

    @Test func copiedSyncIdentityRotatesForAnotherMac() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkCopiedIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.CopiedIdentity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = ICloudDriveSyncCore(
            defaults: defaults, iCloudDriveRootURL: root, deviceName: "Mac A")
        let sourceID = source.deviceID
        source.prepareDeviceIdentity()
        #expect(defaults.integer(forKey: "VoiceInkSyncV3.identityCollisionCheckVersion") == 0)
        _ = try source.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/test", value: Data("value".utf8))
        ]), domain: .configuration)

        let copiedInstallation = ICloudDriveSyncCore(
            defaults: defaults, iCloudDriveRootURL: root, deviceName: "Mac B")
        #expect(copiedInstallation.deviceID == sourceID)
        _ = try copiedInstallation.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/other", value: Data("other".utf8))
        ]), domain: .configuration)

        let repairedInstallation = ICloudDriveSyncCore(
            defaults: defaults, iCloudDriveRootURL: root, deviceName: "Mac B")
        repairedInstallation.prepareDeviceIdentity()
        #expect(repairedInstallation.deviceID != sourceID)
    }

    @Test func renamedMacKeepsItsSyncIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkRenamedIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.RenamedIdentity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = ICloudDriveSyncCore(
            defaults: defaults, iCloudDriveRootURL: root, deviceName: "Old Mac Name")
        let originalID = original.deviceID
        _ = try original.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/test", value: Data("value".utf8))
        ]), domain: .configuration)

        let renamed = ICloudDriveSyncCore(
            defaults: defaults, iCloudDriveRootURL: root, deviceName: "New Mac Name")
        renamed.prepareDeviceIdentity()
        #expect(renamed.deviceID == originalID)
    }

    @Test func readingManyRemoteOperationsUpdatesTheFrontierOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkBatchFrontier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localSuite = "VoiceInkTests.BatchFrontier.Local.\(UUID().uuidString)"
        let remoteSuite = "VoiceInkTests.BatchFrontier.Remote.\(UUID().uuidString)"
        let localDefaults = try #require(UserDefaults(suiteName: localSuite))
        let remoteDefaults = try #require(UserDefaults(suiteName: remoteSuite))
        defer {
            localDefaults.removePersistentDomain(forName: localSuite)
            remoteDefaults.removePersistentDomain(forName: remoteSuite)
        }
        let local = ICloudDriveSyncCore(defaults: localDefaults, iCloudDriveRootURL: root)
        let remote = ICloudDriveSyncCore(defaults: remoteDefaults, iCloudDriveRootURL: root)
        for index in 0..<20 {
            _ = try remote.append(VoiceInkSyncMutationBatch(mutations: [
                VoiceInkSyncMutation(
                    key: "preference/value-\(index)", value: Data("\(index)".utf8))
            ]), domain: .configuration)
        }

        #expect(local.frontierWriteCountForTesting == 0)
        #expect(try local.readAll(in: .configuration).count == 20)
        #expect(local.frontierWriteCountForTesting == 1)
        _ = try local.readAll(in: .configuration)
        #expect(local.frontierWriteCountForTesting == 1)
    }

    @Test func incrementalRegisterDecodesAndPersistsOnlyNewOperations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkIncrementalRegister-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localSuite = "VoiceInkTests.IncrementalRegister.Local.\(UUID().uuidString)"
        let remoteSuite = "VoiceInkTests.IncrementalRegister.Remote.\(UUID().uuidString)"
        let localDefaults = try #require(UserDefaults(suiteName: localSuite))
        let remoteDefaults = try #require(UserDefaults(suiteName: remoteSuite))
        defer {
            localDefaults.removePersistentDomain(forName: localSuite)
            remoteDefaults.removePersistentDomain(forName: remoteSuite)
        }
        let local = ICloudDriveSyncCore(defaults: localDefaults, iCloudDriveRootURL: root)
        let remote = ICloudDriveSyncCore(defaults: remoteDefaults, iCloudDriveRootURL: root)
        _ = try remote.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/first", value: Data("one".utf8))
        ]), domain: .configuration)

        let first = try local.readIncrementally(in: .configuration, fullScan: true)
        #expect(first.affectedKeys == ["preference/first"])
        #expect(local.decodedOperationCountForTesting == 1)
        #expect(local.registerCheckpointWriteCountForTesting == 1)

        let second = try local.readIncrementally(in: .configuration, fullScan: true)
        #expect(second.affectedKeys.isEmpty)
        #expect(local.decodedOperationCountForTesting == 1)
        #expect(local.registerCheckpointWriteCountForTesting == 1)

        let appended = try remote.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/second", value: Data("two".utf8))
        ]), domain: .configuration)
        let appendedURL = try #require(remote.operationURL(for: appended))
        let third = try local.readIncrementally(
            in: .configuration,
            hintedOperationURLs: [appendedURL],
            fullScan: false
        )
        #expect(third.affectedKeys == ["preference/second"])
        #expect(third.register.selectedValues().count == 2)
        #expect(local.decodedOperationCountForTesting == 2)
        #expect(local.registerCheckpointWriteCountForTesting == 2)

        // File Provider enumeration can temporarily omit an already-consumed immutable item.
        // The materialized checkpoint must remain usable instead of entering a retry loop.
        try FileManager.default.removeItem(at: appendedURL)
        let fourth = try local.readIncrementally(in: .configuration, fullScan: true)
        #expect(fourth.affectedKeys.isEmpty)
        #expect(fourth.register.selectedValues().count == 2)
        #expect(local.decodedOperationCountForTesting == 2)
        #expect(local.registerCheckpointWriteCountForTesting == 2)
    }

    @Test func syncEnvelopeCarriesDeviceNameAndDecodesLegacyOperations() throws {
        let deviceID = UUID().uuidString
        let batch = VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(key: "preference/language", value: Data("en".utf8))
        ])
        let envelope = VoiceInkSyncEnvelope(
            domain: .configuration,
            authorDeviceID: deviceID,
            authorDeviceName: "Studio Mac",
            authorSequence: 1,
            versionClock: [deviceID: 1],
            payload: try PropertyListEncoder().encode(batch)
        )
        let encoded = try PropertyListEncoder().encode(envelope)
        let decoded = try PropertyListDecoder().decode(VoiceInkSyncEnvelope.self, from: encoded)
        #expect(decoded.authorDeviceName == "Studio Mac")
        #expect(decoded.authorDisplayName == "Studio Mac")
        #expect(decoded.isValid)

        var legacyPropertyList = try #require(
            PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
        )
        legacyPropertyList.removeValue(forKey: "authorDeviceName")
        let legacyData = try PropertyListSerialization.data(
            fromPropertyList: legacyPropertyList, format: .binary, options: 0)
        let legacy = try PropertyListDecoder().decode(VoiceInkSyncEnvelope.self, from: legacyData)
        #expect(legacy.authorDeviceName == nil)
        #expect(legacy.authorDisplayName == String(deviceID.prefix(8)))
        #expect(legacy.isValid)
    }

    @Test func syncCoreShortCircuitsOwnOperationsAndFiltersDomains() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkOperationSource-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localSuite = "VoiceInkTests.OperationSource.Local.\(UUID().uuidString)"
        let remoteSuite = "VoiceInkTests.OperationSource.Remote.\(UUID().uuidString)"
        let localDefaults = try #require(UserDefaults(suiteName: localSuite))
        let remoteDefaults = try #require(UserDefaults(suiteName: remoteSuite))
        defer {
            localDefaults.removePersistentDomain(forName: localSuite)
            remoteDefaults.removePersistentDomain(forName: remoteSuite)
        }
        let local = ICloudDriveSyncCore(
            defaults: localDefaults, iCloudDriveRootURL: root, deviceName: "Local Mac")
        let remote = ICloudDriveSyncCore(
            defaults: remoteDefaults, iCloudDriveRootURL: root, deviceName: "Remote Mac")
        let mutation = VoiceInkSyncMutation(key: "preference/language", value: Data("en".utf8))
        let ownEnvelope = try local.append(
            VoiceInkSyncMutationBatch(mutations: [mutation]), domain: .configuration)
        let remoteEnvelope = try remote.append(
            VoiceInkSyncMutationBatch(mutations: [mutation]), domain: .dictionary)
        let files = try syncOperationFiles(root: root, domain: .configuration)
            + syncOperationFiles(root: root, domain: .dictionary)
        let ownURL = try #require(files.first {
            local.operationLocation(for: $0)?.operationID == ownEnvelope.operationID
        })
        let remoteURL = try #require(files.first {
            local.operationLocation(for: $0)?.operationID == remoteEnvelope.operationID
        })

        #expect(!local.shouldConsumeRemoteOperation(
            at: ownURL, domains: [.configuration, .dictionary]))
        #expect(!local.shouldConsumeRemoteOperation(at: remoteURL, domains: [.configuration]))
        #expect(local.shouldConsumeRemoteOperation(at: remoteURL, domains: [.dictionary]))
    }

    @Test func foregroundCatchUpSyncRunsOnlyAfterReconciliationInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recent = now.addingTimeInterval(-(30 * 60 - 1))
        let due = now.addingTimeInterval(-30 * 60)

        #expect(!CloudConfigurationSyncService.shouldRunCatchUpSync(lastSyncedAt: nil, now: now))
        #expect(!CloudConfigurationSyncService.shouldRunCatchUpSync(lastSyncedAt: recent, now: now))
        #expect(CloudConfigurationSyncService.shouldRunCatchUpSync(lastSyncedAt: due, now: now))
        #expect(!CloudUsageDataSyncService.shouldRunCatchUpSync(lastSyncedAt: nil, now: now))
        #expect(!CloudUsageDataSyncService.shouldRunCatchUpSync(lastSyncedAt: recent, now: now))
        #expect(CloudUsageDataSyncService.shouldRunCatchUpSync(lastSyncedAt: due, now: now))
    }

    @Test func iCloudSyncCoordinatorRunsOffMainAndSerializesWork() async throws {
        let coordinator = ICloudSyncExecutionCoordinator(
            label: "VoiceInkTests.SyncCoordinator.\(UUID().uuidString)"
        )
        let probe = ICloudSyncConcurrencyProbe()
        let wasOffMain = try await coordinator.run {
            probe.enter()
            defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.02)
            return !Thread.isMainThread && ICloudSyncExecutionCoordinator.isExecutingOnSyncQueue
        }
        async let first: Void = coordinator.run {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.03)
            probe.leave()
        }
        async let second: Void = coordinator.run {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.03)
            probe.leave()
        }
        _ = try await (first, second)

        #expect(wasOffMain)
        #expect(probe.maximumActive == 1)
    }

    @Test func iCloudSyncRetryPolicyUsesBoundedExponentialDelays() {
        #expect(ICloudSyncRetryPolicy.baseDelay(afterFailureCount: 1) == 5)
        #expect(ICloudSyncRetryPolicy.baseDelay(afterFailureCount: 2) == 15)
        #expect(ICloudSyncRetryPolicy.baseDelay(afterFailureCount: 3) == 30)
        #expect(ICloudSyncRetryPolicy.baseDelay(afterFailureCount: 4) == 60)
        #expect(ICloudSyncRetryPolicy.baseDelay(afterFailureCount: 5) == 300)
        #expect(ICloudSyncRetryPolicy.baseDelay(afterFailureCount: 100) == 300)
    }

    @Test func audioDescriptorRejectsUnsafeCloudPaths() {
        #expect(
            CloudUsageDataSyncService.AudioDescriptor(
                sha256: String(repeating: "a", count: 64), byteCount: 1, fileExtension: "wav"
            ).isValid
        )
        #expect(
            !CloudUsageDataSyncService.AudioDescriptor(
                sha256: String(repeating: "a", count: 64), byteCount: 1, fileExtension: "../wav"
            ).isValid
        )
        #expect(
            !CloudUsageDataSyncService.AudioDescriptor(
                sha256: "not-a-digest", byteCount: 1, fileExtension: "wav"
            ).isValid
        )
    }

    private func syncEnvelope(
        operationID: UUID,
        deviceID: String,
        sequence: UInt64,
        domain: VoiceInkSyncDomain = .configuration,
        mutation: VoiceInkSyncMutation
    ) throws -> (envelope: VoiceInkSyncEnvelope, batch: VoiceInkSyncMutationBatch) {
        let batch = VoiceInkSyncMutationBatch(mutations: [mutation])
        let payload = try PropertyListEncoder().encode(batch)
        return (
            VoiceInkSyncEnvelope(
                operationID: operationID,
                domain: domain,
                authorDeviceID: deviceID,
                authorSequence: sequence,
                versionClock: [deviceID: sequence],
                payload: payload
            ),
            batch
        )
    }

    @Test func cloudAndRetentionDefaultsArePrivacyPreservingAndStorageBounded() throws {
        let suiteName = "VoiceInkTests.SyncDefaults"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        AppDefaults.registerDefaults(in: defaults)

        #expect(defaults.bool(forKey: CloudSyncSettingsKeys.configurationSyncEnabled))
        #expect(!defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled))
        #expect(!defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled))
        #expect(defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryRecordCount) == 0)
        #expect(
            defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
                == HistoryStorageSettings.defaultMegabytes
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    @Test func localAudioDeduplicationDeletesOnlyUnreferencedStableExactCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkLocalAudioDedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicateData = Data(repeating: 0x2a, count: 4_096)
        let uniqueData = Data(repeating: 0x7b, count: 2_048)
        let referenced = root.appendingPathComponent("referenced.wav")
        let duplicate = root.appendingPathComponent("duplicate.wav")
        let unique = root.appendingPathComponent("unique.wav")
        let recentDuplicate = root.appendingPathComponent("recent-duplicate.wav")
        try duplicateData.write(to: referenced)
        try duplicateData.write(to: duplicate)
        try uniqueData.write(to: unique)
        try duplicateData.write(to: recentDuplicate)

        let container = try ModelContainer(
            for: Schema([Transcription.self, SessionMetric.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let transcription = Transcription(
            text: "keep", duration: 1, audioFileURL: referenced.absoluteString)
        container.mainContext.insert(transcription)
        try container.mainContext.save()

        let result = try LocalAudioDeduplicationService.removeSafeDuplicateOrphans(
            modelContainer: container,
            recordingsDirectory: root
        )

        #expect(result == LocalAudioDeduplicationResult(
            deletedFileCount: 2,
            reclaimedByteCount: Int64(duplicateData.count * 2)
        ))
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
        #expect(FileManager.default.fileExists(atPath: unique.path))
        #expect(!FileManager.default.fileExists(atPath: recentDuplicate.path))
    }

    @MainActor
    @Test func localAudioDeduplicationUsesLiveMainContextReferenceSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkLocalAudioDedupLiveContext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioData = Data(repeating: 0x5c, count: 4_096)
        let referenced = root.appendingPathComponent("referenced.wav")
        let duplicate = root.appendingPathComponent("duplicate.wav")
        try audioData.write(to: referenced)
        try audioData.write(to: duplicate)

        let container = try ModelContainer(
            for: Schema([Transcription.self, SessionMetric.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        container.mainContext.insert(Transcription(
            text: "live", duration: 1, audioFileURL: referenced.absoluteString
        ))

        let result = try LocalAudioDeduplicationService.removeSafeDuplicateOrphans(
            modelContainer: container,
            recordingsDirectory: root
        )

        #expect(result == LocalAudioDeduplicationResult(
            deletedFileCount: 1,
            reclaimedByteCount: Int64(audioData.count)
        ))
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
    }

    @Test func localAudioDeduplicationUsesSuppliedSyncContextSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkLocalAudioDedupSyncContext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioData = Data(repeating: 0x6d, count: 4_096)
        let referenced = root.appendingPathComponent("synced-record.wav")
        let staleOrphan = root.appendingPathComponent("legacy-record.wav")
        try audioData.write(to: referenced)
        try audioData.write(to: staleOrphan)

        let result = try LocalAudioDeduplicationService.removeSafeDuplicateOrphans(
            referencedPaths: [referenced.standardizedFileURL.path],
            recordingsDirectory: root
        )

        #expect(result == LocalAudioDeduplicationResult(
            deletedFileCount: 1,
            reclaimedByteCount: Int64(audioData.count)
        ))
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(!FileManager.default.fileExists(atPath: staleOrphan.path))
    }

    @Test func historyStorageCapacityUsesDefaultAndClampsSupportedRange() throws {
        let suiteName = "VoiceInkTests.HistoryStorageCapacity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AppDefaults.registerDefaults(in: defaults)

        #expect(HistoryStorageSettings.allowedMegabytes == 100...102_400)
        #expect(HistoryStorageSettings.activationDelay == 30)
        #expect(HistoryStorageSettings.cleanupCheckInterval == 3_600)
        #expect(HistoryStorageSettings.currentMegabytes(in: defaults) == 500)

        defaults.set(0, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        #expect(HistoryStorageSettings.currentMegabytes(in: defaults) == 500)
        #expect(defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes) == 500)

        defaults.set(99, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        #expect(HistoryStorageSettings.currentMegabytes(in: defaults) == 100)

        defaults.set(200_000, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        #expect(HistoryStorageSettings.currentMegabytes(in: defaults) == 102_400)
        #expect(defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes) == 102_400)
    }

    @Test func historyStorageCleanupOnlyManagesAudioInsideRecordingsDirectory() {
        let recordingsDirectory = URL(fileURLWithPath: "/tmp/VoiceInk/Recordings", isDirectory: true)

        #expect(
            HistoryStorageManager.isManagedAudioURL(
                recordingsDirectory.appendingPathComponent("old.wav"),
                recordingsDirectory: recordingsDirectory
            )
        )
        #expect(
            !HistoryStorageManager.isManagedAudioURL(
                URL(fileURLWithPath: "/tmp/VoiceInk/Recordings-archive/old.wav"),
                recordingsDirectory: recordingsDirectory
            )
        )
        #expect(
            !HistoryStorageManager.isManagedAudioURL(
                URL(fileURLWithPath: "/tmp/user-owned.wav"),
                recordingsDirectory: recordingsDirectory
            )
        )
    }

    @Test func historyStorageCleanupScheduleHonorsActivationDelayAndHourlyCadence() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(
            !HistoryStorageManager.isAutomaticCleanupDue(
                now: now,
                lastCheckDate: nil,
                activationDate: now.addingTimeInterval(1)
            )
        )
        #expect(
            !HistoryStorageManager.isAutomaticCleanupDue(
                now: now,
                lastCheckDate: now.addingTimeInterval(-3_599),
                activationDate: nil
            )
        )
        #expect(
            HistoryStorageManager.isAutomaticCleanupDue(
                now: now,
                lastCheckDate: now.addingTimeInterval(-3_600),
                activationDate: nil
            )
        )
    }

    @Test func transcriptionStagePerformanceRoundTripsThroughPersistedData() throws {
        var original = TranscriptionPerformanceSnapshot(executionMode: "nativeStreaming")
        original.streamingResolution = "providerFinal"
        original.connectionDuration = 0.21
        original.firstPartialLatency = 0.44
        original.firstCommitLatency = 0.83
        original.drainDuration = 0.12
        original.finalizationDuration = 0.09
        original.fallbackDuration = 4.2
        original.fallbackError = "CloudTranscriptionError: connection closed"
        original.transcriptionDuration = 2.1
        original.postProcessingDuration = 0.08
        original.enhancementDuration = 0.7
        original.deliveryDuration = 0.03
        original.totalProcessingDuration = 2.9
        original.receivedChunks = 42
        original.sentChunks = 42
        original.droppedChunks = 0
        original.receivedBytes = 268_800
        original.sentBytes = 268_800
        let transcription = Transcription(text: "同步阶段性能", duration: 4.2)
        transcription.performanceSnapshot = original

        #expect(transcription.performanceData != nil)
        #expect(transcription.performanceSnapshot == original)

        let metric = SessionMetric(
            transcriptionId: transcription.id,
            wordCount: 8,
            audioDuration: 4.2,
            transcriptionModelName: "streaming-model",
            transcriptionDuration: 2.1,
            speedFactor: 2,
            modeName: nil,
            aiEnhancementModelName: nil,
            enhancementDuration: 0.7,
            performanceData: transcription.performanceData
        )
        #expect(metric.performanceData == transcription.performanceData)
    }

    @Test func legacyPerformanceSnapshotWithoutFallbackErrorStillDecodes() throws {
        let legacyJSON = Data(
            #"{"schemaVersion":1,"executionMode":"nativeStreaming","fallbackDuration":1.25}"#.utf8
        )

        let snapshot = try JSONDecoder().decode(TranscriptionPerformanceSnapshot.self, from: legacyJSON)

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.fallbackDuration == 1.25)
        #expect(snapshot.fallbackError == nil)
    }

    @Test func diagnosticLogRetentionUsesSevenDaysAndFiftyMiB() {
        let policy = LogExportRetentionPolicy.voiceInkDefault
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(policy.maximumAge == 7 * 24 * 60 * 60)
        #expect(policy.maximumBytes == 50 * 1_024 * 1_024)
        #expect(policy.cutoffDate(relativeTo: now) == now.addingTimeInterval(-7 * 24 * 60 * 60))
    }

    @Test func diagnosticLogBufferDropsOldestLinesAndHonorsByteLimit() {
        var buffer = BoundedDiagnosticLogBuffer(maximumBytes: 8)
        buffer.append("old")
        buffer.append("new")
        buffer.append("tail")

        #expect(buffer.lines == ["tail"])
        #expect(buffer.byteCount <= 8)
        #expect(buffer.droppedLineCount == 2)

        var oversizedBuffer = BoundedDiagnosticLogBuffer(maximumBytes: 8)
        oversizedBuffer.append("1234567890")
        #expect(oversizedBuffer.lines == ["1234567"])
        #expect(oversizedBuffer.byteCount == 8)
    }

    @Test func historyCapacityLimitsUseEitherThreshold() {
        #expect(
            HistoryStorageManager.shouldDelete(
                recordCount: 10_000,
                managedBytes: 100_000_000_000,
                maximumRecordCount: 0,
                maximumBytes: Int64(HistoryStorageSettings.defaultMegabytes) * 1_024 * 1_024
            )
        )
        #expect(
            HistoryStorageManager.shouldDelete(
                recordCount: 501,
                managedBytes: 100,
                maximumRecordCount: 500,
                maximumBytes: 0
            )
        )
        #expect(
            HistoryStorageManager.shouldDelete(
                recordCount: 10,
                managedBytes: 1_024,
                maximumRecordCount: 500,
                maximumBytes: 1_000
            )
        )
    }

    @Test func cloudUsageSnapshotPreservesEveryPerformanceStage() throws {
        var performance = TranscriptionPerformanceSnapshot(executionMode: "slidingWindow")
        performance.connectionDuration = 0.4
        performance.firstPartialLatency = 0.8
        performance.transcriptionDuration = 1.7
        performance.postProcessingDuration = 0.06
        performance.enhancementDuration = 0.5
        performance.deliveryDuration = 0.02
        performance.totalProcessingDuration = 2.3
        performance.receivedChunks = 30
        performance.sentChunks = 30
        let performanceData = try JSONEncoder().encode(performance)
        let transcriptionID = UUID()
        let payload = CloudUsageDataSyncService.TranscriptionPayload(
            id: transcriptionID,
            text: "完整输入",
            enhancedText: "润色结果",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 3.5,
            transcriptionModelName: "Parakeet CTC 0.6B (中文)",
            aiEnhancementModelName: "qwen",
            promptName: "Polish",
            transcriptionDuration: 1.7,
            enhancementDuration: 0.5,
            modeName: "中文",
            modeEmoji: "📝",
            transcriptionStatus: "completed",
            performanceData: performanceData
        )
        let snapshot = CloudUsageDataSyncService.Snapshot(
            schemaVersion: CloudUsageDataSyncService.Snapshot.currentSchemaVersion,
            revisionID: UUID(),
            sourceDeviceID: "test-mac",
            sourceDeviceName: "Test Mac",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010),
            transcription: payload,
            metric: nil,
            audio: nil
        )

        let data = try PropertyListEncoder().encode(snapshot)
        let decoded = try PropertyListDecoder().decode(CloudUsageDataSyncService.Snapshot.self, from: data)
        let decodedPerformanceData = try #require(decoded.transcription.performanceData)
        let decodedPerformance = try JSONDecoder().decode(
            TranscriptionPerformanceSnapshot.self,
            from: decodedPerformanceData
        )

        #expect(decoded == snapshot)
        #expect(decodedPerformance == performance)

        var snapshotWithRemovedEditTrackingFields = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        var legacyTranscription = try #require(
            snapshotWithRemovedEditTrackingFields["transcription"] as? [String: Any]
        )
        legacyTranscription["deliveredText"] = "legacy delivered text"
        legacyTranscription["finalEditedText"] = "legacy edited text"
        legacyTranscription["pasteTrackingStatus"] = "edited"
        legacyTranscription["postPasteEditHistoryData"] = Data([0x01])
        snapshotWithRemovedEditTrackingFields["transcription"] = legacyTranscription
        let legacyEditTrackingData = try PropertyListSerialization.data(
            fromPropertyList: snapshotWithRemovedEditTrackingFields,
            format: .binary,
            options: 0
        )
        let decodedLegacyEditTrackingSnapshot = try PropertyListDecoder().decode(
            CloudUsageDataSyncService.Snapshot.self,
            from: legacyEditTrackingData
        )
        #expect(decodedLegacyEditTrackingSnapshot == snapshot)

        var legacyPropertyList = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        legacyPropertyList["schemaVersion"] = 1
        legacyPropertyList.removeValue(forKey: "sourceDeviceName")
        let legacyData = try PropertyListSerialization.data(
            fromPropertyList: legacyPropertyList,
            format: .binary,
            options: 0
        )
        let legacySnapshot = try PropertyListDecoder().decode(
            CloudUsageDataSyncService.Snapshot.self,
            from: legacyData
        )
        #expect(legacySnapshot.schemaVersion == 1)
        #expect(legacySnapshot.sourceDeviceName == nil)
    }

    @MainActor
    @Test func historyCapacityCleanupDeletesOldestRecordsFirst() async throws {
        let previousCount = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.maximumHistoryRecordCount)
        let previousStorage = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        defer {
            UserDefaults.standard.set(previousCount, forKey: CleanupSettingsKeys.maximumHistoryRecordCount)
            UserDefaults.standard.set(previousStorage, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        }
        UserDefaults.standard.set(2, forKey: CleanupSettingsKeys.maximumHistoryRecordCount)
        UserDefaults.standard.set(0, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)

        let schema = Schema([Transcription.self, SessionMetric.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let timestamps = [100.0, 200.0, 300.0]
        for (index, timestamp) in timestamps.enumerated() {
            let record = Transcription(text: "record-\(index)", duration: 1)
            record.timestamp = Date(timeIntervalSince1970: timestamp)
            context.insert(record)
        }
        try context.save()

        let result = await HistoryStorageManager.shared.enforceLimits(modelContext: context)
        let remaining = try context.fetch(
            FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\Transcription.timestamp)])
        )

        #expect(result.deletedRecordCount == 1)
        #expect(remaining.map(\.text) == ["record-1", "record-2"])
    }


    @MainActor
    @Test func cloudUsageSyncRequestsOnlyTheUsageOperationDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceInkUsageDownloadRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "VoiceInkTests.UsageDownloadRequest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)

        let fileManager = DownloadRequestRecordingFileManager()
        let schema = Schema([Transcription.self, SessionMetric.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let service = CloudUsageDataSyncService(
            defaults: defaults,
            fileManager: fileManager,
            iCloudDriveRootURL: root
        )

        service.start(modelContext: container.mainContext)
        try await waitForUsageSync(service)
        service.setEnabled(false)

        let expectedUsageDirectory = root.appendingPathComponent(
            "VoiceInk/Sync/v3/Operations/usage", isDirectory: true
        ).standardizedFileURL
        #expect(!fileManager.downloadRequests.isEmpty)
        #expect(fileManager.downloadRequests.allSatisfy { $0 == expectedUsageDirectory })
    }

    @MainActor
    @Test func cloudUsageBulkSyncImportsHistoryWithoutReexportingAtSteadyState() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkSteadyUsageSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let suiteName = "VoiceInkTests.SteadyUsageSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)

        let schema = Schema([Transcription.self, SessionMetric.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        for index in 0..<200 {
            let transcription = Transcription(text: "record-\(index)", duration: 1)
            container.mainContext.insert(transcription)
            container.mainContext.insert(SessionMetric(
                transcriptionId: transcription.id,
                wordCount: 1,
                audioDuration: 1,
                transcriptionModelName: "bulk-model",
                transcriptionDuration: 0.5,
                speedFactor: 2,
                modeName: "Dictation",
                aiEnhancementModelName: nil,
                enhancementDuration: nil
            ))
        }
        try container.mainContext.save()

        let service = CloudUsageDataSyncService(defaults: defaults, iCloudDriveRootURL: temporaryRoot)
        service.start(modelContext: container.mainContext)
        try await waitForUsageSync(service)
        #expect(service.lastExportCandidateCount == 200)
        #expect(try syncOperationFiles(root: temporaryRoot, domain: .usage).count == 1)

        let receivingSuiteName = "VoiceInkTests.SteadyUsageSync.Receiving.\(UUID().uuidString)"
        let receivingDefaults = try #require(UserDefaults(suiteName: receivingSuiteName))
        defer { receivingDefaults.removePersistentDomain(forName: receivingSuiteName) }
        receivingDefaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        let receivingContainer = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let receivingService = CloudUsageDataSyncService(
            defaults: receivingDefaults,
            iCloudDriveRootURL: temporaryRoot
        )
        receivingService.start(modelContext: receivingContainer.mainContext)
        try await waitForUsageSync(receivingService)
        #expect(try receivingContainer.mainContext.fetchCount(FetchDescriptor<Transcription>()) == 200)
        #expect(try receivingContainer.mainContext.fetchCount(FetchDescriptor<SessionMetric>()) == 200)
        #expect(receivingService.lastImportCandidateCount == 200)
        receivingService.setEnabled(false)

        let bootstrapSyncDate = try #require(service.lastSyncedAt)
        service.syncNow()
        try await waitForUsageSync(service, after: bootstrapSyncDate)
        #expect(service.lastExportCandidateCount == 0)
        #expect(service.lastImportCandidateCount == 0)
        #expect(!service.lastSyncUsedLegacyScan)
        service.setEnabled(false)
    }

    @MainActor
    @Test func cloudUsageSyncToleratesDuplicateBusinessUUIDsWithoutDeletingRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceInkDuplicateUsageUUIDs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSuite = "VoiceInkTests.DuplicateUsageUUIDs.Source.\(UUID().uuidString)"
        let receivingSuite = "VoiceInkTests.DuplicateUsageUUIDs.Receiving.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let receivingDefaults = try #require(UserDefaults(suiteName: receivingSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            receivingDefaults.removePersistentDomain(forName: receivingSuite)
        }
        sourceDefaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        receivingDefaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        receivingDefaults.set(
            true, forKey: "CloudUsageDataSyncV3.localBootstrapCompleted")

        let schema = Schema([Transcription.self, SessionMetric.self])
        let sourceContainer = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let duplicateRecordID = UUID()
        let sparseTranscription = Transcription(text: "short", duration: 1)
        sparseTranscription.id = duplicateRecordID
        sparseTranscription.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let completeTranscription = Transcription(
            text: "the complete duplicate survives sync", duration: 2,
            enhancedText: "complete enhanced text", transcriptionModelName: "complete-model",
            modeName: "Dictation", transcriptionStatus: .completed)
        completeTranscription.id = duplicateRecordID
        completeTranscription.timestamp = Date(timeIntervalSince1970: 1_700_000_001)
        sourceContainer.mainContext.insert(sparseTranscription)
        sourceContainer.mainContext.insert(completeTranscription)

        let duplicateMetricID = UUID()
        let sparseMetric = SessionMetric(
            transcriptionId: duplicateRecordID, source: nil, wordCount: 1, audioDuration: 1,
            transcriptionModelName: nil, transcriptionDuration: nil, speedFactor: nil, modeName: nil,
            aiEnhancementModelName: nil, enhancementDuration: nil)
        sparseMetric.id = duplicateMetricID
        sparseMetric.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let completeMetric = SessionMetric(
            transcriptionId: duplicateRecordID, source: "recorder", wordCount: 6, audioDuration: 2,
            transcriptionModelName: "complete-model", transcriptionDuration: 1, speedFactor: 2,
            modeName: "Dictation", aiEnhancementModelName: "enhancer", enhancementDuration: 0.2,
            enhancementEstimatedTokenCount: 8, performanceData: Data([0x01, 0x02]))
        completeMetric.id = duplicateMetricID
        completeMetric.timestamp = Date(timeIntervalSince1970: 1_700_000_001)
        sourceContainer.mainContext.insert(sparseMetric)
        sourceContainer.mainContext.insert(completeMetric)
        try sourceContainer.mainContext.save()

        let source = CloudUsageDataSyncService(
            defaults: sourceDefaults, iCloudDriveRootURL: root, deviceName: "Source Mac")
        source.start(modelContext: sourceContainer.mainContext)
        try await waitForUsageSync(source)

        // Sync treats duplicate business UUIDs as one logical value, while leaving
        // every physical historical row untouched for lossless recovery.
        #expect(try sourceContainer.mainContext.fetchCount(FetchDescriptor<Transcription>()) == 2)
        #expect(try sourceContainer.mainContext.fetchCount(FetchDescriptor<SessionMetric>()) == 2)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == 1)

        let receivingContainer = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let preservedTranscriptionText = "preserved local detail"
        let receivingSparseTranscription = Transcription(
            text: preservedTranscriptionText, duration: 1)
        receivingSparseTranscription.id = duplicateRecordID
        receivingSparseTranscription.timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        let receivingOtherTranscription = Transcription(
            text: "local duplicate", duration: 1, transcriptionModelName: "old-model")
        receivingOtherTranscription.id = duplicateRecordID
        receivingOtherTranscription.timestamp = Date(timeIntervalSince1970: 1_600_000_001)
        receivingOtherTranscription.performanceData = Data(repeating: 0x2a, count: 128)
        receivingContainer.mainContext.insert(receivingSparseTranscription)
        receivingContainer.mainContext.insert(receivingOtherTranscription)
        let receivingSparseMetric = SessionMetric(
            transcriptionId: duplicateRecordID, source: nil, wordCount: 1, audioDuration: 1,
            transcriptionModelName: nil, transcriptionDuration: nil, speedFactor: nil, modeName: nil,
            aiEnhancementModelName: nil, enhancementDuration: nil)
        receivingSparseMetric.id = duplicateMetricID
        let receivingOtherMetric = SessionMetric(
            transcriptionId: duplicateRecordID, wordCount: 2, audioDuration: 1,
            transcriptionModelName: "old-model", transcriptionDuration: 1, speedFactor: 1,
            modeName: nil, aiEnhancementModelName: nil, enhancementDuration: nil)
        receivingOtherMetric.id = duplicateMetricID
        receivingContainer.mainContext.insert(receivingSparseMetric)
        receivingContainer.mainContext.insert(receivingOtherMetric)
        try receivingContainer.mainContext.save()
        let receiving = CloudUsageDataSyncService(
            defaults: receivingDefaults, iCloudDriveRootURL: root, deviceName: "Receiving Mac")
        receiving.start(modelContext: receivingContainer.mainContext)
        try await waitForUsageSync(receiving)

        let importedTranscriptions = try receivingContainer.mainContext.fetch(
            FetchDescriptor<Transcription>())
        let importedMetrics = try receivingContainer.mainContext.fetch(
            FetchDescriptor<SessionMetric>())
        #expect(importedTranscriptions.count == 2)
        #expect(importedTranscriptions.allSatisfy { $0.id == duplicateRecordID })
        #expect(importedTranscriptions.contains {
            $0.text == "the complete duplicate survives sync"
                && $0.transcriptionModelName == "complete-model"
        })
        #expect(importedTranscriptions.contains { $0.text == preservedTranscriptionText })
        #expect(importedMetrics.count == 2)
        #expect(importedMetrics.allSatisfy {
            $0.id == duplicateMetricID && $0.transcriptionId == duplicateRecordID
        })
        #expect(importedMetrics.contains { $0.transcriptionModelName == "complete-model" })
        #expect(receiving.lastRemoteDeviceName == "Source Mac")

        let operationCount = try syncOperationFiles(root: root, domain: .usage).count
        let secondSyncStart = try #require(receiving.lastSyncedAt)
        receiving.syncNow()
        try await waitForUsageSync(receiving, after: secondSyncStart)
        let steadyTranscriptions = try receivingContainer.mainContext.fetch(
            FetchDescriptor<Transcription>())
        let steadyMetrics = try receivingContainer.mainContext.fetch(
            FetchDescriptor<SessionMetric>())
        #expect(steadyTranscriptions.contains { $0.text == preservedTranscriptionText })
        #expect(steadyMetrics.contains { $0.transcriptionModelName == nil })
        #expect(try syncOperationFiles(root: root, domain: .usage).count == operationCount)
        source.setEnabled(false)
        receiving.setEnabled(false)
    }

    @MainActor
    private func waitForUsageSync(_ service: CloudUsageDataSyncService) async throws {
        let timeout = Date().addingTimeInterval(20)
        while service.lastSyncedAt == nil && Date() < timeout {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(service.state == .synced)
        #expect(service.lastSyncedAt != nil)
    }

    @MainActor
    private func waitForUsageSync(_ service: CloudUsageDataSyncService, after date: Date) async throws {
        let timeout = Date().addingTimeInterval(5)
        while (service.lastSyncedAt ?? .distantPast) <= date && Date() < timeout {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(service.state == .synced)
        #expect((service.lastSyncedAt ?? .distantPast) > date)
    }

    @MainActor
    @Test func disablingUsageSyncWhileQueuedDoesNotPublishStaleCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsageDisableGeneration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.UsageDisableGeneration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)

        let coordinator = ICloudSyncExecutionCoordinator(
            label: "VoiceInkTests.UsageDisableGeneration.\(UUID().uuidString)"
        )
        let probe = ICloudSyncConcurrencyProbe()
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            try await coordinator.run {
                probe.markBlockerStarted()
                release.wait()
            }
        }
        let blockerTimeout = Date().addingTimeInterval(5)
        while !probe.hasBlockerStarted && Date() < blockerTimeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.hasBlockerStarted)

        let container = try ModelContainer(
            for: Schema([Transcription.self, SessionMetric.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let service = CloudUsageDataSyncService(
            defaults: defaults, iCloudDriveRootURL: root, executionCoordinator: coordinator
        )
        service.start(modelContext: container.mainContext)
        #expect(service.isSyncRunningForTesting)
        service.setEnabled(false)
        release.signal()
        try await blocker.value

        let completionTimeout = Date().addingTimeInterval(5)
        while service.isSyncRunningForTesting && Date() < completionTimeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!service.isSyncRunningForTesting)
        #expect(service.state == .disabled)
        #expect(service.lastSyncedAt == nil)
    }

    @MainActor
    private func waitForConfigurationSync(
        _ service: CloudConfigurationSyncService,
        after date: Date = .distantPast
    ) async throws {
        let timeout = Date().addingTimeInterval(20)
        while (service.lastSyncedAt ?? .distantPast) <= date && Date() < timeout {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(service.state == .synced)
        #expect((service.lastSyncedAt ?? .distantPast) > date)
    }

    @MainActor
    private func synchronizeConfigurationServices(
        _ services: [CloudConfigurationSyncService]
    ) async throws {
        for service in services {
            let start = service.lastSyncedAt ?? .distantPast
            service.syncNow()
            try await waitForConfigurationSync(service, after: start)
        }
    }

    @MainActor
    @Test func cloudUsageV3SyncsEveryMetricAudioAndGlobalDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsageV3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteA = "VoiceInkTests.UsageV3.A.\(UUID().uuidString)"
        let suiteB = "VoiceInkTests.UsageV3.B.\(UUID().uuidString)"
        let defaultsA = try #require(UserDefaults(suiteName: suiteA))
        let defaultsB = try #require(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        for defaults in [defaultsA, defaultsB] {
            defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
            defaults.set(true, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        }

        let schema = Schema([Transcription.self, SessionMetric.self])
        let containerA = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let containerB = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let record = Transcription(text: "v3 history", duration: 2.5)
        let audio = root.appendingPathComponent("source.wav")
        try Data(repeating: 0x5a, count: 8_192).write(to: audio)
        record.audioFileURL = audio.absoluteString
        containerA.mainContext.insert(record)
        let metricA = SessionMetric(
            transcriptionId: record.id, wordCount: 2, audioDuration: 2.5,
            transcriptionModelName: "model-a", transcriptionDuration: 1, speedFactor: 2.5,
            modeName: "Dictation", aiEnhancementModelName: nil, enhancementDuration: nil)
        let metricB = SessionMetric(
            transcriptionId: record.id, source: "file", wordCount: 3, audioDuration: 2.5,
            transcriptionModelName: "model-b", transcriptionDuration: 1.2, speedFactor: 2,
            modeName: "Notes", aiEnhancementModelName: "qwen", enhancementDuration: 0.4)
        containerA.mainContext.insert(metricA)
        containerA.mainContext.insert(metricB)
        try containerA.mainContext.save()

        let recordingsA = root.appendingPathComponent("LocalRecordings-A", isDirectory: true)
        let recordingsB = root.appendingPathComponent("LocalRecordings-B", isDirectory: true)
        let serviceA = CloudUsageDataSyncService(
            defaults: defaultsA, iCloudDriveRootURL: root, deviceName: "Usage Mac A",
            localRecordingsDirectoryURL: recordingsA)
        serviceA.start(modelContext: containerA.mainContext)
        try await waitForUsageSync(serviceA)
        let serviceB = CloudUsageDataSyncService(
            defaults: defaultsB, iCloudDriveRootURL: root, deviceName: "Usage Mac B",
            localRecordingsDirectoryURL: recordingsB)
        serviceB.start(modelContext: containerB.mainContext)
        try await waitForUsageSync(serviceB)
        #expect(serviceB.lastRemoteDeviceName == "Usage Mac A")

        let imported = try #require(containerB.mainContext.fetch(FetchDescriptor<Transcription>()).first)
        #expect(imported.id == record.id)
        #expect(imported.text == "v3 history")
        #expect(try containerB.mainContext.fetch(FetchDescriptor<SessionMetric>()).count == 2)
        #expect(imported.audioFileURL == nil)
        #expect(serviceB.hasCloudAudio(for: imported.id))
        try FileManager.default.createDirectory(at: recordingsB, withIntermediateDirectories: true)
        let obsoleteAudio = recordingsB
            .appendingPathComponent("synced_\(imported.id.uuidString).m4a")
        try Data(repeating: 0x11, count: 64).write(to: obsoleteAudio)
        let importedAudio = try await serviceB.materializeAudioOnDemand(for: imported.id)
        #expect(try Data(contentsOf: importedAudio) == Data(repeating: 0x5a, count: 8_192))
        #expect(importedAudio.lastPathComponent == "synced_\(imported.id.uuidString).wav")
        #expect(!FileManager.default.fileExists(atPath: obsoleteAudio.path))
        #expect(try await serviceB.materializeAudioOnDemand(for: imported.id) == importedAudio)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == 1)

        let deleteStart = try #require(serviceB.lastSyncedAt)
        serviceB.deleteRecordsGlobally([record.id])
        containerB.mainContext.delete(imported)
        for metric in try containerB.mainContext.fetch(FetchDescriptor<SessionMetric>()) {
            containerB.mainContext.delete(metric)
        }
        try containerB.mainContext.save()
        serviceB.syncNow()
        try await waitForUsageSync(serviceB, after: deleteStart)
        let pullStart = try #require(serviceA.lastSyncedAt)
        serviceA.syncNow()
        try await waitForUsageSync(serviceA, after: pullStart)
        #expect(serviceA.lastRemoteDeviceName == "Usage Mac B")

        #expect(try containerA.mainContext.fetch(FetchDescriptor<Transcription>()).isEmpty)
        #expect(try containerA.mainContext.fetch(FetchDescriptor<SessionMetric>()).isEmpty)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == 2)
        serviceA.setEnabled(false)
        serviceB.setEnabled(false)
    }

    @MainActor
    @Test func cloudUsageV3LocalCleanupCanBeRestoredWithoutCloudWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsageLocalCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.UsageLocalCleanup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)

        let schema = Schema([Transcription.self, SessionMetric.self])
        let sourceContainer = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let localContainer = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let record = Transcription(text: "restore me", duration: 1)
        sourceContainer.mainContext.insert(record)
        try sourceContainer.mainContext.save()
        let sourceSuite = "VoiceInkTests.UsageLocalCleanup.Source.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        sourceDefaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        let source = CloudUsageDataSyncService(
            defaults: sourceDefaults, iCloudDriveRootURL: root,
            localRecordingsDirectoryURL: root.appendingPathComponent("LocalRecordings-Source"))
        source.start(modelContext: sourceContainer.mainContext)
        try await waitForUsageSync(source)

        let local = CloudUsageDataSyncService(
            defaults: defaults, iCloudDriveRootURL: root,
            localRecordingsDirectoryURL: root.appendingPathComponent("LocalRecordings-Local"))
        local.start(modelContext: localContainer.mainContext)
        try await waitForUsageSync(local)
        let imported = try #require(localContainer.mainContext.fetch(FetchDescriptor<Transcription>()).first)
        let operationCount = try syncOperationFiles(root: root, domain: .usage).count
        local.recordsWereRemovedLocally([imported.id])
        localContainer.mainContext.delete(imported)
        try localContainer.mainContext.save()
        let suppressedStart = try #require(local.lastSyncedAt)
        local.syncNow()
        try await waitForUsageSync(local, after: suppressedStart)
        #expect(try localContainer.mainContext.fetch(FetchDescriptor<Transcription>()).isEmpty)
        #expect(local.locallySuppressedRecordCount == 1)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == operationCount)

        let restoreStart = try #require(local.lastSyncedAt)
        local.restoreLocallySuppressedRecords()
        try await waitForUsageSync(local, after: restoreStart)
        #expect(try localContainer.mainContext.fetch(FetchDescriptor<Transcription>()).first?.text == "restore me")
        #expect(local.locallySuppressedRecordCount == 0)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == operationCount)
        source.setEnabled(false)
        local.setEnabled(false)
    }

    @MainActor
    @Test func localCleanupWhileUsageSyncIsOffRemainsSuppressedWhenEnabledLater() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkDisabledCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.DisabledCleanup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recordID = UUID()
        let service = CloudUsageDataSyncService(defaults: defaults, iCloudDriveRootURL: root)

        #expect(!defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled))
        service.recordsWereRemovedLocally([recordID])
        #expect(service.locallySuppressedRecordCount == 1)

        service.restoreLocallySuppressedRecords()
        #expect(service.locallySuppressedRecordCount == 0)
    }

    @MainActor
    @Test func cloudConfigurationV3SyncsEditsWithoutEchoWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkConfigurationV3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteA = "VoiceInkTests.ConfigurationV3.A.\(UUID().uuidString)"
        let suiteB = "VoiceInkTests.ConfigurationV3.B.\(UUID().uuidString)"
        let defaultsA = try #require(UserDefaults(suiteName: suiteA))
        let defaultsB = try #require(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        defaultsA.set(true, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        defaultsB.set(true, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        defaultsA.set("en", forKey: "SelectedLanguage")
        let schema = Schema([VocabularyWord.self, WordReplacement.self])
        let containerA = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let containerB = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let serviceA = CloudConfigurationSyncService(
            defaults: defaultsA, iCloudDriveRootURL: root, preferencesDomainName: suiteA,
            deviceName: "Configuration Mac A")
        let serviceB = CloudConfigurationSyncService(
            defaults: defaultsB, iCloudDriveRootURL: root, preferencesDomainName: suiteB,
            deviceName: "Configuration Mac B")
        #expect(serviceA.localDeviceName == "Configuration Mac A")
        #expect(serviceB.localDeviceName == "Configuration Mac B")
        serviceA.start(modelContext: containerA.mainContext, onRemoteConfigurationApplied: {})
        serviceB.start(modelContext: containerB.mainContext, onRemoteConfigurationApplied: {})
        try await waitForConfigurationSync(serviceA)
        try await waitForConfigurationSync(serviceB)
        try await synchronizeConfigurationServices([serviceA, serviceB])
        #expect(defaultsB.string(forKey: "SelectedLanguage") == "en")
        #expect(serviceB.lastRemoteDeviceName == "Configuration Mac A")
        #expect(try syncOperationFiles(root: root, domain: .configuration).count == 1)

        defaultsB.set("zh-Hans", forKey: "SelectedLanguage")
        let editStartB = try #require(serviceB.lastSyncedAt)
        serviceB.syncNow()
        try await waitForConfigurationSync(serviceB, after: editStartB)
        let pullStartA = try #require(serviceA.lastSyncedAt)
        serviceA.syncNow()
        try await waitForConfigurationSync(serviceA, after: pullStartA)
        #expect(defaultsA.string(forKey: "SelectedLanguage") == "zh-Hans")
        #expect(serviceA.lastRemoteDeviceName == "Configuration Mac B")
        let operationCount = try syncOperationFiles(root: root, domain: .configuration).count
        #expect(operationCount == 2)
        let steadyStartA = try #require(serviceA.lastSyncedAt)
        serviceA.syncNow()
        try await waitForConfigurationSync(serviceA, after: steadyStartA)
        let steadyStartB = try #require(serviceB.lastSyncedAt)
        serviceB.syncNow()
        try await waitForConfigurationSync(serviceB, after: steadyStartB)
        #expect(try syncOperationFiles(root: root, domain: .configuration).count == operationCount)
        #expect(serviceA.lastRemoteDeviceName == "Configuration Mac B")
        #expect(serviceA.configurationConflictCount == 0)
        #expect(serviceB.configurationConflictCount == 0)
        serviceA.setEnabled(false)
        serviceB.setEnabled(false)
    }

    @MainActor
    @Test func cloudConfigurationIgnoresUnchangedDefaultsNotifications() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkConfigurationIdle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.ConfigurationIdle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        defaults.set("en", forKey: "SelectedLanguage")
        let container = try ModelContainer(
            for: VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = CloudConfigurationSyncService(
            defaults: defaults, iCloudDriveRootURL: root, preferencesDomainName: suite)
        service.start(modelContext: container.mainContext, onRemoteConfigurationApplied: {})
        try await waitForConfigurationSync(service)
        try await Task.sleep(for: .seconds(1))
        let lastSync = try #require(service.lastSyncedAt)
        let operationCount = try syncOperationFiles(root: root, domain: .configuration).count

        defaults.set(UUID().uuidString, forKey: "CloudUsageDataSyncV3.internalChange")
        try await Task.sleep(for: .seconds(1.2))

        #expect(service.lastSyncedAt == lastSync)
        #expect(try syncOperationFiles(root: root, domain: .configuration).count == operationCount)
        service.setEnabled(false)
    }

    @MainActor
    @Test func cloudUsageImportsTextAndMetricsWhileAudioIsPending() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsagePendingAudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSuite = "VoiceInkTests.PendingAudio.Source.\(UUID().uuidString)"
        let receivingSuite = "VoiceInkTests.PendingAudio.Receiving.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let receivingDefaults = try #require(UserDefaults(suiteName: receivingSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            receivingDefaults.removePersistentDomain(forName: receivingSuite)
        }
        let recordID = UUID()
        let metricID = UUID()
        let audio = CloudUsageDataSyncService.AudioDescriptor(
            sha256: String(repeating: "a", count: 64), byteCount: 4_096, fileExtension: "wav")
        let transcription = CloudUsageDataSyncService.TranscriptionPayload(
            id: recordID, text: "text survives pending audio", enhancedText: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), duration: 2,
            transcriptionModelName: "test-model", aiEnhancementModelName: nil, promptName: nil,
            transcriptionDuration: 1, enhancementDuration: nil, modeName: "Dictation",
            modeEmoji: nil, transcriptionStatus: "completed", performanceData: nil)
        let metric = CloudUsageDataSyncService.MetricPayload(
            id: metricID, transcriptionId: recordID, timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            source: "recorder", wordCount: 4, audioDuration: 2,
            transcriptionModelName: "test-model", transcriptionDuration: 1, speedFactor: 2,
            modeName: "Dictation", aiEnhancementModelName: nil, enhancementDuration: nil,
            enhancementEstimatedTokenCount: nil, performanceData: nil)
        let sourceCore = ICloudDriveSyncCore(
            defaults: sourceDefaults, iCloudDriveRootURL: root, deviceName: "Audio Source Mac")
        _ = try sourceCore.append(VoiceInkSyncMutationBatch(mutations: [
            VoiceInkSyncMutation(
                key: "transcription/\(recordID.uuidString)",
                value: try PropertyListEncoder().encode(
                    CloudUsageDataSyncService.TranscriptionValue(
                        transcription: transcription, audio: audio))),
            VoiceInkSyncMutation(
                key: "metric/\(recordID.uuidString)/\(metricID.uuidString)",
                value: try PropertyListEncoder().encode(metric)),
        ]), domain: .usage)

        receivingDefaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        receivingDefaults.set(true, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        let container = try ModelContainer(
            for: Schema([Transcription.self, SessionMetric.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let service = CloudUsageDataSyncService(
            defaults: receivingDefaults, iCloudDriveRootURL: root, deviceName: "Receiving Mac",
            localRecordingsDirectoryURL: root.appendingPathComponent("LocalRecordings"))
        service.start(modelContext: container.mainContext)
        try await waitForUsageSync(service)

        let imported = try #require(container.mainContext.fetch(FetchDescriptor<Transcription>()).first)
        #expect(imported.text == "text survives pending audio")
        #expect(imported.audioFileURL == nil)
        #expect(service.hasCloudAudio(for: imported.id))
        #expect(try container.mainContext.fetch(FetchDescriptor<SessionMetric>()).first?.id == metricID)
        #expect(service.state == .synced)
        #expect(service.lastRemoteDeviceName == "Audio Source Mac")
        service.setEnabled(false)
        #expect(!service.hasCloudAudio(for: imported.id))
        await #expect(throws: CocoaError.self) {
            _ = try await service.materializeAudioOnDemand(for: imported.id)
        }
    }

    @MainActor
    @Test func cloudConfigurationStructuredEntitiesUseStableEncodingWithoutEchoWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkStableConfig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "VoiceInkTests.StableConfig.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        defaults.set(try JSONEncoder().encode([
            CustomPrompt(title: "Stable", promptText: "Keep semantic JSON stable")
        ]), forKey: "customPrompts")
        let container = try ModelContainer(
            for: VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = CloudConfigurationSyncService(
            defaults: defaults, iCloudDriveRootURL: root, preferencesDomainName: suite
        )
        service.start(modelContext: container.mainContext, onRemoteConfigurationApplied: {})
        try await waitForConfigurationSync(service)
        let initialCount = try syncOperationFiles(root: root, domain: .configuration).count
        #expect(initialCount == 1)

        for _ in 0..<3 {
            let start = try #require(service.lastSyncedAt)
            service.syncNow()
            try await waitForConfigurationSync(service, after: start)
        }
        #expect(try syncOperationFiles(root: root, domain: .configuration).count == initialCount)
        service.setEnabled(false)
    }

    @MainActor
    @Test func cloudUsageV3MigratesLegacySnapshotAndVerifiedAudioOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsageV3Migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordID = UUID()
        let metricID = UUID()
        let legacyRoot = root.appendingPathComponent("VoiceInk/UsageData/v1", isDirectory: true)
        let audioData = Data(repeating: 0x2a, count: 4_096)
        let audioDigest = VoiceInkSyncEnvelope.sha256(audioData)
        let audio = CloudUsageDataSyncService.AudioDescriptor(
            sha256: audioDigest, byteCount: Int64(audioData.count), fileExtension: "wav")
        let blob = legacyRoot
            .appendingPathComponent("Blobs/Audio/\(String(audioDigest.prefix(2)))", isDirectory: true)
            .appendingPathComponent("\(audioDigest).wav")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audioData.write(to: blob)
        let transcription = CloudUsageDataSyncService.TranscriptionPayload(
            id: recordID, text: "legacy v1", enhancedText: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), duration: 3,
            transcriptionModelName: "legacy-model", aiEnhancementModelName: nil, promptName: nil,
            transcriptionDuration: 1.5, enhancementDuration: nil, modeName: "Dictation",
            modeEmoji: nil, transcriptionStatus: "completed", performanceData: nil)
        let metric = CloudUsageDataSyncService.MetricPayload(
            id: metricID, transcriptionId: recordID, timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            source: "recorder", wordCount: 2, audioDuration: 3, transcriptionModelName: "legacy-model",
            transcriptionDuration: 1.5, speedFactor: 2, modeName: "Dictation",
            aiEnhancementModelName: nil, enhancementDuration: nil, enhancementEstimatedTokenCount: nil,
            performanceData: nil)
        let snapshot = CloudUsageDataSyncService.Snapshot(
            schemaVersion: 2, revisionID: UUID(), sourceDeviceID: UUID().uuidString,
            sourceDeviceName: "Legacy Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_002),
            transcription: transcription, metric: metric, audio: audio)
        let snapshotURL = legacyRoot
            .appendingPathComponent("Records/\(recordID.uuidString)", isDirectory: true)
            .appendingPathComponent("legacy.plist")
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(snapshot).write(to: snapshotURL)

        let suite = "VoiceInkTests.UsageV3Migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        let schema = Schema([Transcription.self, SessionMetric.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let localRecordings = root.appendingPathComponent("LocalRecordings", isDirectory: true)
        let service = CloudUsageDataSyncService(
            defaults: defaults, iCloudDriveRootURL: root,
            localRecordingsDirectoryURL: localRecordings)
        service.start(modelContext: container.mainContext)
        try await waitForUsageSync(service)

        let imported = try #require(container.mainContext.fetch(FetchDescriptor<Transcription>()).first)
        #expect(imported.id == recordID)
        #expect(imported.text == "legacy v1")
        #expect(try container.mainContext.fetch(FetchDescriptor<SessionMetric>()).first?.id == metricID)
        #expect(imported.audioFileURL == nil)
        #expect(service.hasCloudAudio(for: imported.id))
        let importedAudio = try await service.materializeAudioOnDemand(for: imported.id)
        #expect(try Data(contentsOf: importedAudio) == audioData)
        #expect(service.lastSyncUsedLegacyScan)
        let operationCount = try syncOperationFiles(root: root, domain: .usage).count
        #expect(operationCount == 1)
        let hashCountAfterImport = service.audioHashCountForTesting
        #expect(hashCountAfterImport > 0)
        let firstSync = try #require(service.lastSyncedAt)
        service.syncNow()
        try await waitForUsageSync(service, after: firstSync)
        #expect(!service.lastSyncUsedLegacyScan)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == operationCount)
        #expect(service.audioHashCountForTesting == hashCountAfterImport)
        #expect(defaults.data(forKey: "CloudUsageDataSyncV3.appliedOperationIDs") == nil)
        service.setEnabled(false)
    }

    @MainActor
    @Test func cloudUsageV3BatchesLegacyMigrationIntoFewOperations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsageV3BulkMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRecords = root.appendingPathComponent(
            "VoiceInk/UsageData/v1/Records", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRecords, withIntermediateDirectories: true)

        for index in 0..<200 {
            let recordID = UUID()
            let metricID = UUID()
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            let transcription = CloudUsageDataSyncService.TranscriptionPayload(
                id: recordID, text: "legacy bulk \(index)", enhancedText: nil,
                timestamp: timestamp, duration: 1, transcriptionModelName: "legacy-model",
                aiEnhancementModelName: nil, promptName: nil, transcriptionDuration: 0.5,
                enhancementDuration: nil, modeName: "Dictation", modeEmoji: nil,
                transcriptionStatus: "completed", performanceData: nil)
            let metric = CloudUsageDataSyncService.MetricPayload(
                id: metricID, transcriptionId: recordID, timestamp: timestamp, source: "recorder",
                wordCount: 3, audioDuration: 1, transcriptionModelName: "legacy-model",
                transcriptionDuration: 0.5, speedFactor: 2, modeName: "Dictation",
                aiEnhancementModelName: nil, enhancementDuration: nil,
                enhancementEstimatedTokenCount: nil, performanceData: nil)
            let snapshot = CloudUsageDataSyncService.Snapshot(
                schemaVersion: 2, revisionID: UUID(), sourceDeviceID: UUID().uuidString,
                sourceDeviceName: "Legacy Bulk Mac", updatedAt: timestamp,
                transcription: transcription, metric: metric, audio: nil)
            let snapshotURL = legacyRecords
                .appendingPathComponent(recordID.uuidString, isDirectory: true)
                .appendingPathComponent("legacy.plist")
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(snapshot).write(to: snapshotURL)
        }

        let suite = "VoiceInkTests.UsageV3BulkMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        let container = try ModelContainer(
            for: Schema([Transcription.self, SessionMetric.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let service = CloudUsageDataSyncService(defaults: defaults, iCloudDriveRootURL: root)
        service.start(modelContext: container.mainContext)
        try await waitForUsageSync(service)

        #expect(service.lastSyncUsedLegacyScan)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Transcription>()) == 200)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SessionMetric>()) == 200)
        #expect(try syncOperationFiles(root: root, domain: .usage).count == 1)
        service.setEnabled(false)
    }

    @MainActor
    @Test func cloudDictionaryV3NormalizesDuplicatesAndPreservesConcurrentEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkDictionaryV3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteA = "VoiceInkTests.DictionaryV3.A.\(UUID().uuidString)"
        let suiteB = "VoiceInkTests.DictionaryV3.B.\(UUID().uuidString)"
        let defaultsA = try #require(UserDefaults(suiteName: suiteA))
        let defaultsB = try #require(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        defaultsA.set(true, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        defaultsB.set(true, forKey: CloudSyncSettingsKeys.configurationSyncEnabled)
        let schema = Schema([VocabularyWord.self, WordReplacement.self])
        let containerA = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let containerB = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        containerA.mainContext.insert(VocabularyWord(word: "VoiceInk"))
        try containerA.mainContext.save()
        let serviceA = CloudConfigurationSyncService(
            defaults: defaultsA, iCloudDriveRootURL: root, preferencesDomainName: suiteA)
        let serviceB = CloudConfigurationSyncService(
            defaults: defaultsB, iCloudDriveRootURL: root, preferencesDomainName: suiteB)
        serviceA.start(modelContext: containerA.mainContext, onRemoteConfigurationApplied: {})
        serviceB.start(modelContext: containerB.mainContext, onRemoteConfigurationApplied: {})
        try await waitForConfigurationSync(serviceA)
        try await waitForConfigurationSync(serviceB)
        try await synchronizeConfigurationServices([serviceA, serviceB])
        let wordA = try #require(containerA.mainContext.fetch(FetchDescriptor<VocabularyWord>()).first)
        let wordB = try #require(containerB.mainContext.fetch(FetchDescriptor<VocabularyWord>()).first)
        wordA.word = " VOICEINK "
        try containerA.mainContext.save()
        let editStartA = try #require(serviceA.lastSyncedAt)
        serviceA.syncNow()
        try await waitForConfigurationSync(serviceA, after: editStartA)
        wordB.word = "voiceink"
        try containerB.mainContext.save()
        let editStartB = try #require(serviceB.lastSyncedAt)
        serviceB.syncNow()
        try await waitForConfigurationSync(serviceB, after: editStartB)
        let pullStartA = try #require(serviceA.lastSyncedAt)
        serviceA.syncNow()
        try await waitForConfigurationSync(serviceA, after: pullStartA)

        #expect(serviceA.dictionaryConflictCount == 1)
        #expect(serviceB.dictionaryConflictCount == 1)
        #expect(try containerA.mainContext.fetch(FetchDescriptor<VocabularyWord>()).count == 1)
        #expect(try containerB.mainContext.fetch(FetchDescriptor<VocabularyWord>()).count == 1)
        #expect(try syncOperationFiles(root: root, domain: .dictionary).count == 3)
        serviceA.setEnabled(false)
        serviceB.setEnabled(false)
    }

    private func syncOperationFiles(root: URL, domain: VoiceInkSyncDomain) throws -> [URL] {
        let operations = root.appendingPathComponent(
            "VoiceInk/Sync/v3/Operations/\(domain.rawValue)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: operations.path),
            let enumerator = FileManager.default.enumerator(
                at: operations, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "syncop" else { return nil }
            return url
        }
    }

    @MainActor
    @Test func cloudConfigurationSyncExcludesSecretsAndDeviceState() {
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("Volcengine ArkSelectedModel"))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("modeConfigurationsV2"))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("customPrompts"))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("Shortcut_primaryRecording"))

        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("LocalKeychain_openAIAPIKey"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("selectedAudioDeviceUID"))
        #expect(
            !CloudConfigurationSyncService.isEligiblePreferenceKey(DoubaoSpeechSettings.Keys.poiCityName)
        )
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("hasCompletedOnboardingV2"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("buffered-local-realtime-migrated-v1"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("onboardingStage"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("NSWindow Frame main"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("CloudConfigurationSync.deviceID"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("CloudUsageDataSync.deviceID"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("CloudUsageDataSync.appliedRevisions"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(CloudSyncSettingsKeys.configurationSyncEnabled))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(CloudSyncSettingsKeys.usageDataSyncEnabled))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(CloudSyncSettingsKeys.usageAudioSyncEnabled))
    }

    @MainActor
    @Test func legacyCategorizedVocabularyDataDecodesAsUnifiedVocabulary() throws {
        let legacyBackup = try JSONDecoder().decode(
            WordBackup.self,
            from: Data(#"{"word":"LegacyTerm","kindRawValue":"properNoun"}"#.utf8)
        )
        #expect(legacyBackup.word == "LegacyTerm")

        let legacyCloudData = try PropertyListSerialization.data(
            fromPropertyList: [
                "word": "LegacyCloudTerm",
                "dateAdded": Date(timeIntervalSince1970: 1_700_000_000),
                "kindRawValue": "properNoun",
            ],
            format: .binary,
            options: 0
        )
        let legacyCloudItem = try PropertyListDecoder().decode(
            CloudConfigurationSyncService.VocabularyItem.self,
            from: legacyCloudData
        )
        #expect(legacyCloudItem.word == "LegacyCloudTerm")

        let legacyModel = VocabularyWord(word: "ExistingTerm")
        #expect(legacyModel.word == "ExistingTerm")

        let exportedBackup = try JSONEncoder().encode(WordBackup(word: "UnifiedTerm"))
        let exportedBackupObject = try #require(
            JSONSerialization.jsonObject(with: exportedBackup) as? [String: Any]
        )
        #expect(exportedBackupObject["kindRawValue"] == nil)

        let exportedCloudItem = try PropertyListEncoder().encode(
            CloudConfigurationSyncService.VocabularyItem(
                word: "UnifiedCloudTerm",
                dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let exportedCloudObject = try #require(
            PropertyListSerialization.propertyList(from: exportedCloudItem, format: nil) as? [String: Any]
        )
        #expect(exportedCloudObject["kindRawValue"] == nil)
    }

    @MainActor
    @Test func dictionaryExposesOneVocabularyEntryMode() throws {
        #expect(DictionaryQuickAddView.Mode.allCases == [.vocabulary, .replacement])

        let container = try ModelContainer(
            for: VocabularyWord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "VoiceInk"))
        try context.save()

        let promptContext = CustomVocabularyService.shared.getCustomVocabulary(from: context)
        #expect(promptContext == "Important Vocabulary: VoiceInk")
    }

    @MainActor
    @Test func cloudConfigurationSyncIgnoresRepeatedContentNotifications() {
        let original = CloudConfigurationSyncService.Content(
            preferences: ["mode": Data("original".utf8)],
            vocabulary: [],
            replacements: []
        )
        let changed = CloudConfigurationSyncService.Content(
            preferences: ["mode": Data("changed".utf8)],
            vocabulary: [],
            replacements: []
        )

        #expect(
            CloudConfigurationSyncService.shouldQueueLocalChange(
                current: changed,
                lastKnown: original,
                pending: nil
            )
        )
        #expect(
            !CloudConfigurationSyncService.shouldQueueLocalChange(
                current: changed,
                lastKnown: original,
                pending: changed
            )
        )
        #expect(
            !CloudConfigurationSyncService.shouldQueueLocalChange(
                current: original,
                lastKnown: original,
                pending: nil
            )
        )
    }


    @Test func volcanoArkUsesOpenAICompatibleChatEndpoint() {
        #expect(AIProvider.ark.baseURL == "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        #expect(AIProvider.ark.requiresAPIKey)
        #expect(AIProvider.ark.supportsEnhancement)
        #expect(!AIProvider.ark.isVerificationConfigured(hasAPIKey: true, model: ""))
        #expect(!AIProvider.ark.isVerificationConfigured(hasAPIKey: false, model: "ep-example"))
        #expect(AIProvider.ark.isVerificationConfigured(hasAPIKey: true, model: "ep-example"))
        #expect(AIProvider.openAI.isVerificationConfigured(hasAPIKey: true, model: ""))
    }

    @MainActor
    @Test func missingPromptStorageRestoresBuiltInPrompts() throws {
        let suiteName = "VoiceInkTests.MissingPrompts"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let restored = AIEnhancementService.loadPrompts(from: defaults)
        #expect(restored.first?.id == PromptTemplates.defaultPromptId)

        defaults.set(try JSONEncoder().encode([CustomPrompt]()), forKey: "customPrompts")
        #expect(AIEnhancementService.loadPrompts(from: defaults).isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func adHocPermissionResetCommandsTargetOnlyVoiceInk() {
        let bundleIdentifier = "com.prakashjoshipax.VoiceInk"

        #expect(
            PrivacyPermissionResetService.command(
                for: .accessibility,
                bundleIdentifier: bundleIdentifier
            ) == PrivacyPermissionResetCommand(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "Accessibility", bundleIdentifier]
            )
        )
        #expect(
            PrivacyPermissionResetService.command(
                for: .screenRecording,
                bundleIdentifier: bundleIdentifier
            ) == PrivacyPermissionResetCommand(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "ScreenCapture", bundleIdentifier]
            )
        )
        #expect(
            PrivacyPermissionResetService.command(
                for: .microphone,
                bundleIdentifier: bundleIdentifier
            ) == PrivacyPermissionResetCommand(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "Microphone", bundleIdentifier]
            )
        )
    }

    @Test func bundledChineseASRModelsAreDownloadableAndSelectable() {
        let models = TranscriptionModelRegistry.models
        let expectedNames = [
            "parakeet-ctc-0.6b-zh-cn",
            "sensevoice-small",
            "paraformer-large-zh",
            "qwen3-asr-0.6b-int8",
            "qwen3-asr-0.6b-mlx-int8-streaming",
            "qwen3-asr-0.6b-mlx-streaming",
            "sherpa-zipformer-ctc-zh-int8",
            "ggml-small",
            "ggml-medium",
        ]

        for name in expectedNames {
            let model = models.first { $0.name == name }
            #expect(model != nil, "Missing bundled ASR model: \(name)")
            #expect(model?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)
            #expect(model?.language != "English", "Chinese ASR model is mislabeled as English: \(name)")
        }
    }

    @Test func bufferedLocalModelsExposeRealtimePreview() {
        let expectedNames = [
            "parakeet-ctc-0.6b-zh-cn",
            "sensevoice-small",
            "paraformer-large-zh",
            "qwen3-asr-0.6b-int8",
        ]

        for name in expectedNames {
            let model = TranscriptionModelRegistry.models.first { $0.name == name }
            #expect(model?.supportsStreaming == true, "Missing realtime preview support: \(name)")
        }

        let provider = BufferedOnDeviceStreamingProvider(
            backend: .funASR(FluidAudioTranscriptionService())
        )
        if case .finalizeStreaming = provider.stopDisposition {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "Buffered previews must finalize their last non-empty result")
        }

        var pcm = [Int16.min.littleEndian, 0, Int16.max.littleEndian]
        let pcmData = pcm.withUnsafeMutableBytes { Data($0) }
        let converted = PCMAudioConverter.float32Samples(fromPCM16Data: pcmData)
        #expect(converted == [-1, 0, Float(Int16.max) / 32768])

        let samples: [Float] = [0.1, -0.2, 0.3]
        let prepared = FluidAudioTranscriptionService.prepareSenseVoiceSamples(samples)
        #expect(Array(prepared.prefix(samples.count)) == samples)
        #expect(prepared.count == samples.count + 8_000)

        let qwen3 = TranscriptionModelRegistry.models.first { $0.name == "qwen3-asr-0.6b-int8" }
        #expect(qwen3 != nil)
        if let qwen3 {
            #expect(qwen3.supportedLanguages.count == 31) // 30 languages plus auto-detect.
            #expect(ModelLanguageSupportCatalog.languageCount(for: qwen3) == 52)
        }

        let qwen3MLXModels = TranscriptionModelRegistry.models.filter {
            $0.provider == .qwenMlx
        }
        #expect(qwen3MLXModels.count == 2)
        for qwen3MLX in qwen3MLXModels {
            #expect(qwen3MLX.supportedLanguages.count == 31) // 30 languages plus auto-detect.
            #expect(ModelLanguageSupportCatalog.languageCount(for: qwen3MLX) == 52)
        }
    }

    @MainActor
    @Test func starterAndOnboardingModelsSupportChinese() {
        let starter = TranscriptionModelRegistry.models.first {
            $0.name == StarterModeFactory.defaultTranscriptionModelName
        }
        #expect(starter != nil)
        #expect(starter?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)

        let defaults = UserDefaults(suiteName: "VoiceInkTests.Onboarding")!
        defaults.removePersistentDomain(forName: "VoiceInkTests.Onboarding")
        let onboardingModel = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["en-US"],
            supportsQwenMLX: true
        ).requiredTranscriptionModel
        #expect(onboardingModel?.name == StarterModeFactory.defaultTranscriptionModelName)
        #expect(onboardingModel?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)
    }

    @MainActor
    @Test func chineseOnboardingRecommendsQwenMLXINT8OnAppleSilicon() {
        let defaults = UserDefaults(suiteName: "VoiceInkTests.ChineseOnboarding")!
        defaults.removePersistentDomain(forName: "VoiceInkTests.ChineseOnboarding")

        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            supportsQwenMLX: true
        )

        #expect(coordinator.recommendedLocalTranscriptionModelName == "qwen3-asr-0.6b-mlx-int8-streaming")
        #expect(coordinator.requiredTranscriptionModel?.name == "qwen3-asr-0.6b-mlx-int8-streaming")
        #expect((coordinator.requiredTranscriptionModel as? QwenMLXModel)?.precision == .int8)
    }

    @MainActor
    @Test func chineseOnboardingRecommendationDoesNotReplaceAnExistingModelSelection() {
        let suiteName = "VoiceInkTests.ChineseOnboardingExistingSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("qwen3-asr-0.6b-mlx-streaming", forKey: "CurrentTranscriptionModel")

        _ = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh-Hans"],
            supportsQwenMLX: true
        )

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "qwen3-asr-0.6b-mlx-streaming")
    }

    @MainActor
    @Test func chineseOnboardingFallsBackWhenMLXIsUnavailable() {
        let defaults = UserDefaults(suiteName: "VoiceInkTests.ChineseOnboardingFallback")!
        defaults.removePersistentDomain(forName: "VoiceInkTests.ChineseOnboardingFallback")

        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh_CN"],
            supportsQwenMLX: false
        )

        #expect(coordinator.recommendedLocalTranscriptionModelName == StarterModeFactory.defaultTranscriptionModelName)
        #expect(coordinator.requiredTranscriptionModel?.name == StarterModeFactory.defaultTranscriptionModelName)
    }

}
