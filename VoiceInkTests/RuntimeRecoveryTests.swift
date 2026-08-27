import AppKit
import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
struct RuntimeRecoveryTests {
    @Test func livenessMonitorReportsSoftStallOnceAndRelaunchesOnlyWhenIdle() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: {
                probe.recordHardStall($0)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }

        monitor.simulateTick(now: 7_000_000_000)
        monitor.simulateTick(now: 8_000_000_000)
        #expect(probe.softStalls.count == 1)
        #expect(probe.hardStalls.isEmpty)

        monitor.setCriticalWorkActive(true)
        monitor.simulateTick(now: 40_000_000_000)
        #expect(probe.hardStalls.isEmpty)

        monitor.setCriticalWorkActive(false)
        monitor.simulateTick(now: 41_000_000_000)
        #expect(probe.hardStalls.count == 1)
    }

    @Test func livenessMonitorDetectsAClockDiscontinuityAfterProcessResume() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 8,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: {
                probe.recordHardStall($0)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }

        monitor.simulateTick(now: 12_000_000_000)

        #expect(probe.clockGaps == [11])
    }

    @Test func appKitEventAcknowledgementClearsAStallBeforeEscalation() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: {
                probe.recordHardStall($0)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }

        monitor.simulateTick(now: 7_000_000_000)
        #expect(probe.softStalls.count == 1)
        monitor.acknowledgeAppKitEvent(now: 7_500_000_000)
        monitor.simulateTick(now: 9_000_000_000)

        #expect(probe.softStalls.count == 1)
        #expect(probe.hardStalls.isEmpty)
    }

    @Test @MainActor func appKitProbeAcknowledgesOnlyMatchingDispatchedEvents() throws {
        let eventProbe = AppKitEventProbe()
        defer { eventProbe.stop() }
        var acknowledged = false
        eventProbe.onAcknowledged = {
            acknowledged = true
        }

        let unrelatedEvent = try #require(
            NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 1,
                data1: 0,
                data2: 0
            )
        )
        #expect(eventProbe.handleDispatchedEvent(unrelatedEvent) === unrelatedEvent)
        #expect(!acknowledged)

        let probeEvent = try #require(
            NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: AppKitEventProbe.eventSubtype,
                data1: 1,
                data2: 0
            )
        )
        #expect(eventProbe.handleDispatchedEvent(probeEvent) == nil)

        #expect(acknowledged)
    }

    @Test func hardRecoveryPolicyProtectsRecordingAndTranscriptionWork() {
        #expect(
            !RuntimeRecoveryPolicy.shouldRelaunch(
                stallDuration: RuntimeRecoveryPolicy.hardStallThreshold,
                isCriticalWorkActive: true
            )
        )
        #expect(
            RuntimeRecoveryPolicy.shouldRelaunch(
                stallDuration: RuntimeRecoveryPolicy.hardStallThreshold,
                isCriticalWorkActive: false
            )
        )
    }

    @Test func unavailableHardRecoveryIsRetriedOnLaterWatchdogTicks() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration in
                probe.recordHardStall(duration)
                return probe.hardStalls.count > 1
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }

        monitor.simulateTick(now: 31_000_000_000)
        monitor.simulateTick(now: 32_000_000_000)
        monitor.simulateTick(now: 33_000_000_000)

        #expect(probe.hardStalls.count == 2)
    }

    @Test func memoryPressureSimulationSuspendsWorkThenRecoversOnNormal() {
        #expect(
            RuntimeMemoryPressurePolicy.plan(for: .warning)
                == RuntimeMemoryPressurePlan(suspendOptionalWork: true, performRecovery: false)
        )
        #expect(
            RuntimeMemoryPressurePolicy.plan(for: .critical)
                == RuntimeMemoryPressurePlan(suspendOptionalWork: true, performRecovery: false)
        )
        #expect(
            RuntimeMemoryPressurePolicy.plan(for: .normal)
                == RuntimeMemoryPressurePlan(suspendOptionalWork: false, performRecovery: true)
        )
    }

    @Test func relaunchHelperIsPreparedWithARecoveryCooldown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInk-RuntimeRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let app = root.appendingPathComponent("VoiceInk.app", isDirectory: true)

        let plan = try #require(
            RuntimeRecoveryRelauncher.prepareIfAllowed(
                environment: [:],
                appURL: app,
                cachesDirectory: caches,
                libraryDirectory: library
            )
        )
        #expect(FileManager.default.isExecutableFile(atPath: plan.helperURL.path))
        #expect(RuntimeRecoveryRelauncher.helperScript.contains("/usr/bin/open -n \"$app_path\""))
        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
        syntaxCheck.arguments = ["-n", plan.helperURL.path]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        #expect(syntaxCheck.terminationStatus == 0)

        try Data("recent".utf8).write(to: plan.markerURL, options: .atomic)
        #expect(!plan.canRelaunch(now: Date()))
        #expect(plan.canRelaunch(now: Date().addingTimeInterval(RuntimeRecoveryRelauncher.cooldown + 1)))
    }

    @Test func testProcessesNeverPrepareAnAutomaticRelaunch() {
        let plan = RuntimeRecoveryRelauncher.prepareIfAllowed(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        )
        #expect(plan?.helperURL == nil)
    }

    @Test func failedHelperLaunchClearsTheCooldownMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInk-RuntimeRecoveryFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try #require(
            RuntimeRecoveryRelauncher.prepareIfAllowed(
                environment: [:],
                appURL: root.appendingPathComponent("VoiceInk.app"),
                cachesDirectory: root.appendingPathComponent("Caches"),
                libraryDirectory: root.appendingPathComponent("Library")
            )
        )

        #expect(!plan.launchAndExit(processExecutableURL: root.appendingPathComponent("missing-shell")))
        #expect(!FileManager.default.fileExists(atPath: plan.markerURL.path))
        #expect(plan.canRelaunch())
    }

    @Test @MainActor func overlappingModelOperationsRemainProtectedUntilAllFinish() {
        let activity = ModelManagementActivity.shared
        let first = activity.begin()
        let second = activity.begin()
        #expect(activity.isBusy)
        #expect(activity.activeOperationCount == 2)

        activity.end(first)
        #expect(activity.isBusy)
        #expect(activity.activeOperationCount == 1)

        activity.end(second)
        #expect(!activity.isBusy)
        #expect(activity.activeOperationCount == 0)
    }

    @Test @MainActor func pendingAudioFilesRemainProtectedBeforeProcessingStarts() throws {
        let manager = AudioTranscriptionManager.shared
        manager.clearAll()
        defer { manager.clearAll() }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInk-PendingAudio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try Data(repeating: 0, count: 44).write(to: audioURL)

        manager.addToQueue(urls: [audioURL])
        let queuedItem = try #require(manager.queue.first)
        #expect(manager.hasQueuedWork)

        manager.removeFromQueue(id: queuedItem.id)
        #expect(!manager.hasQueuedWork)
    }
}

private final class RuntimeRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClockGaps: [TimeInterval] = []
    private var storedSoftStalls: [(TimeInterval, Bool)] = []
    private var storedHardStalls: [TimeInterval] = []

    var clockGaps: [TimeInterval] { lock.withLock { storedClockGaps } }
    var softStalls: [(TimeInterval, Bool)] { lock.withLock { storedSoftStalls } }
    var hardStalls: [TimeInterval] { lock.withLock { storedHardStalls } }

    func recordClockGap(_ duration: TimeInterval) {
        lock.withLock { storedClockGaps.append(duration) }
    }

    func recordSoftStall(_ duration: TimeInterval, critical: Bool) {
        lock.withLock { storedSoftStalls.append((duration, critical)) }
    }

    func recordHardStall(_ duration: TimeInterval) {
        lock.withLock { storedHardStalls.append(duration) }
    }
}
