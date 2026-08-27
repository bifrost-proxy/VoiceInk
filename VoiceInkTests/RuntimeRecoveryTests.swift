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
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, shouldProceed in
                guard shouldProceed() else { return false }
                probe.recordHardStall(duration)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)

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
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, shouldProceed in
                guard shouldProceed() else { return false }
                probe.recordHardStall(duration)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)

        monitor.simulateTick(now: 12_000_000_000)

        #expect(probe.clockGaps == [11])
        #expect(probe.clockGapCriticalStates == [false])
    }

    @Test func appKitEventAcknowledgementClearsAStallBeforeEscalation() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, shouldProceed in
                guard shouldProceed() else { return false }
                probe.recordHardStall(duration)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)

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

    @Test func watchdogDoesNotEscalateBeforeAppKitDispatchesItsFirstProbe() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, shouldProceed in
                guard shouldProceed() else { return false }
                probe.recordHardStall(duration)
                return true
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }

        monitor.simulateTick(now: 40_000_000_000)
        #expect(probe.softStalls.isEmpty)
        #expect(probe.hardStalls.isEmpty)

        monitor.acknowledgeAppKitEvent(now: 40_000_000_000)
        monitor.simulateTick(now: 71_000_000_000)
        #expect(probe.hardStalls.count == 1)
    }

    @Test func terminationPermanentlyDisarmsTheWatchdog() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, _ in
                probe.recordHardStall(duration)
                return true
            }
        )
        monitor.start(interval: 1_000)
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)
        monitor.disarmPermanently()

        monitor.simulateTick(now: 40_000_000_000)
        #expect(probe.softStalls.isEmpty)
        #expect(probe.hardStalls.isEmpty)
    }

    @Test func hardRecoveryRevalidatesTheLatestAppKitAcknowledgement() {
        let probe = RuntimeRecoveryProbe()
        let monitorBox = LivenessMonitorBox()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, shouldProceed in
                monitorBox.monitor?.acknowledgeAppKitEvent(now: 31_000_000_000)
                guard shouldProceed() else { return false }
                probe.recordHardStall(duration)
                return true
            }
        )
        monitorBox.monitor = monitor
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)

        monitor.simulateTick(now: 31_000_000_000)
        #expect(probe.hardStalls.isEmpty)
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
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { duration, critical in probe.recordSoftStall(duration, critical: critical) },
            onHardStall: { duration, shouldProceed in
                guard shouldProceed() else { return false }
                probe.recordHardStall(duration)
                return probe.hardStalls.count > 1
            }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)

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

        var eventGate = RuntimeMemoryPressureEventGate()
        let acceptedNewerEvent = eventGate.accept(sequence: 2)
        let acceptedOlderEvent = eventGate.accept(sequence: 1)
        #expect(acceptedNewerEvent)
        #expect(!acceptedOlderEvent)
        #expect(eventGate.latestSequence == 2)
        #expect(
            RuntimeMemoryPressurePolicy.plan(for: .critical)
                == RuntimeMemoryPressurePlan(suspendOptionalWork: true, performRecovery: false)
        )
        #expect(
            RuntimeMemoryPressurePolicy.plan(for: .normal)
                == RuntimeMemoryPressurePlan(suspendOptionalWork: false, performRecovery: true)
        )

        let coalescedRecovery: DispatchSource.MemoryPressureEvent = [.critical, .normal]
        #expect(RuntimeMemoryPressurePolicy.level(for: coalescedRecovery) == .normal)
    }

    @Test func pressureResourceReleaseWaitsForRecordingAndModelWorkToFinish() {
        #expect(
            RuntimePressureResourceReleasePolicy.canRelease(
                activeOperationCount: 0,
                isRecordingActive: false
            )
        )
        #expect(
            !RuntimePressureResourceReleasePolicy.canRelease(
                activeOperationCount: 1,
                isRecordingActive: false
            )
        )
        #expect(
            !RuntimePressureResourceReleasePolicy.canRelease(
                activeOperationCount: 0,
                isRecordingActive: true
            )
        )
    }

    @Test @MainActor func memoryPressureTransitionsSerializeAcrossSuspensionAwait() async {
        let queue = RuntimeMemoryPressureTransitionQueue()
        let gate = NonCooperativeTaskGate()
        let probe = OrderedTransitionProbe()

        #expect(queue.enqueue(sequence: 1) {
            probe.append("warning-start")
            await gate.wait()
            probe.append("warning-finished")
        })
        await Task.yield()
        #expect(queue.enqueue(sequence: 2) {
            probe.append("normal")
        })
        #expect(probe.values == ["warning-start"])

        await gate.release()
        await queue.waitForIdle()
        #expect(probe.values == ["warning-start", "warning-finished", "normal"])
    }

    @Test @MainActor func pressureReleaseWaitsForOperationsFromEveryRegistry() async {
        let coordinator = RuntimePressureOperationCoordinator()
        let probe = OrderedTransitionProbe()

        #expect(await coordinator.beginOperation())
        #expect(await coordinator.beginOperation())
        let releaseTask = Task { @MainActor in
            await coordinator.requestRelease(
                recordingIsActive: { false },
                operation: {
                    probe.append("released")
                    return true
                }
            )
        }
        await Task.yield()
        #expect(!(await releaseTask.value))
        #expect(probe.values.isEmpty)

        coordinator.endOperation()
        await Task.yield()
        #expect(probe.values.isEmpty)

        coordinator.endOperation()
        _ = await coordinator.retryPendingRelease()
        #expect(probe.values == ["released"])
    }

    @Test @MainActor func pressureReleaseBlocksNewOperationsForItsFullAsyncWindow() async {
        let coordinator = RuntimePressureOperationCoordinator()
        let gate = NonCooperativeTaskGate()
        let probe = OrderedTransitionProbe()

        let releaseTask = Task { @MainActor in
            await coordinator.requestRelease(
                recordingIsActive: { false },
                operation: {
                    probe.append("release-started")
                    await gate.wait()
                    probe.append("release-finished")
                    return true
                }
            )
        }
        await Task.yield()
        let operationTask = Task { @MainActor in
            let started = await coordinator.beginOperation()
            if started {
                probe.append("operation-started")
            }
            return started
        }
        await Task.yield()
        #expect(probe.values == ["release-started"])

        await gate.release()
        #expect(await releaseTask.value)
        #expect(await operationTask.value)
        coordinator.endOperation()
        #expect(probe.values == ["release-started", "release-finished", "operation-started"])
    }

    @Test @MainActor func pressureRecoveryCancelsAnInFlightStaleRelease() async {
        let coordinator = RuntimePressureOperationCoordinator()
        let gate = NonCooperativeTaskGate()
        let probe = OrderedTransitionProbe()

        let releaseTask = Task { @MainActor in
            await coordinator.requestRelease(
                recordingIsActive: { false },
                operation: {
                    probe.append("release-started")
                    await gate.wait()
                    guard !Task.isCancelled else {
                        probe.append("release-cancelled")
                        return false
                    }
                    probe.append("release-finished")
                    return true
                }
            )
        }
        await Task.yield()
        coordinator.cancelPendingRelease()
        await gate.release()

        #expect(!(await releaseTask.value))
        #expect(probe.values == ["release-started", "release-cancelled"])
        #expect(!coordinator.hasPendingRelease)
        #expect(!coordinator.isReleasingResources)
    }

    @Test func watchdogKeepsOnlyOneAppKitProbeOutstanding() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 1_000,
            clock: { 1_000_000_000 },
            onProbeRequested: { probe.recordProbeRequest() },
            onClockDiscontinuity: { _, _ in },
            onSoftStall: { _, _ in },
            onHardStall: { _, _ in false }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)

        monitor.simulateTick(now: 2_000_000_000, enqueueMainProbe: true)
        monitor.simulateTick(now: 3_000_000_000, enqueueMainProbe: true)
        #expect(probe.probeRequestCount == 1)

        monitor.acknowledgeAppKitEvent(now: 3_500_000_000)
        monitor.simulateTick(now: 4_000_000_000, enqueueMainProbe: true)
        #expect(probe.probeRequestCount == 2)
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

    @Test func missingHelperPreventsExitAndClearsTheCooldownMarker() throws {
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

        try FileManager.default.removeItem(at: plan.helperURL)
        #expect(!plan.launchAndExit())
        #expect(!FileManager.default.fileExists(atPath: plan.markerURL.path))
        #expect(plan.canRelaunch())
    }

    @Test @MainActor func overlappingModelOperationsRemainProtectedUntilAllFinish() {
        let activity = RuntimeProtectedWorkActivity.shared
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

    @Test @MainActor func supersededPrewarmTasksRemainTrackedUntilEachFinishes() async {
        let registry = ModelPrewarmTaskRegistry()
        let firstGate = NonCooperativeTaskGate()
        let secondGate = NonCooperativeTaskGate()
        let firstID = UUID()
        let secondID = UUID()
        let firstTask = Task { await firstGate.wait() }
        registry.insert(firstTask, id: firstID)
        registry.cancelAll()
        let secondTask = Task { await secondGate.wait() }
        registry.insert(secondTask, id: secondID)

        let outstandingTasks = registry.cancelAll()
        #expect(registry.count == 2)
        #expect(outstandingTasks.count == 2)

        await firstGate.release()
        await secondGate.release()
        for task in outstandingTasks {
            await task.value
        }
        registry.remove(id: firstID)
        registry.remove(id: secondID)
        #expect(registry.isEmpty)
    }

    @Test func clockDiscontinuityReportsProtectedWorkState() {
        let probe = RuntimeRecoveryProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: 5,
            hardStallThreshold: 30,
            clockDiscontinuityThreshold: 8,
            clock: { 1_000_000_000 },
            onClockDiscontinuity: { probe.recordClockGap($0, critical: $1) },
            onSoftStall: { _, _ in },
            onHardStall: { _, shouldProceed in shouldProceed() }
        )
        monitor.start(interval: 1_000)
        defer { monitor.stop() }
        monitor.acknowledgeAppKitEvent(now: 1_000_000_000)
        monitor.setCriticalWorkActive(true)

        monitor.simulateTick(now: 12_000_000_000)

        #expect(probe.clockGapCriticalStates == [true])
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
    private var storedClockGapCriticalStates: [Bool] = []
    private var storedSoftStalls: [(TimeInterval, Bool)] = []
    private var storedHardStalls: [TimeInterval] = []
    private var storedProbeRequestCount = 0

    var clockGaps: [TimeInterval] { lock.withLock { storedClockGaps } }
    var clockGapCriticalStates: [Bool] { lock.withLock { storedClockGapCriticalStates } }
    var softStalls: [(TimeInterval, Bool)] { lock.withLock { storedSoftStalls } }
    var hardStalls: [TimeInterval] { lock.withLock { storedHardStalls } }
    var probeRequestCount: Int { lock.withLock { storedProbeRequestCount } }

    func recordClockGap(_ duration: TimeInterval, critical: Bool) {
        lock.withLock {
            storedClockGaps.append(duration)
            storedClockGapCriticalStates.append(critical)
        }
    }

    func recordSoftStall(_ duration: TimeInterval, critical: Bool) {
        lock.withLock { storedSoftStalls.append((duration, critical)) }
    }

    func recordHardStall(_ duration: TimeInterval) {
        lock.withLock { storedHardStalls.append(duration) }
    }

    func recordProbeRequest() {
        lock.withLock { storedProbeRequestCount += 1 }
    }
}

private actor NonCooperativeTaskGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class LivenessMonitorBox: @unchecked Sendable {
    weak var monitor: MainThreadLivenessMonitor?
}

@MainActor
private final class OrderedTransitionProbe {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
