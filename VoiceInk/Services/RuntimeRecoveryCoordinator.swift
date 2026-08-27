import AppIntents
import AppKit
import Atomics
import Combine
import Darwin
import Foundation
import OSLog

enum RuntimeRecoveryReason: String, Codable, Sendable {
    case systemWake
    case screenWake
    case sessionBecameActive
    case memoryPressureRecovered
    case clockDiscontinuity
}

enum RuntimeRecoveryPolicy {
    static let softStallThreshold: TimeInterval = 5
    static let hardStallThreshold: TimeInterval = 30
    static let clockDiscontinuityThreshold: TimeInterval = 8

    static func shouldRelaunch(stallDuration: TimeInterval, isCriticalWorkActive: Bool) -> Bool {
        stallDuration >= hardStallThreshold && !isCriticalWorkActive
    }
}

enum RuntimeMemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical
}

struct RuntimeMemoryPressurePlan: Equatable, Sendable {
    let suspendOptionalWork: Bool
    let performRecovery: Bool
}

enum RuntimeMemoryPressurePolicy {
    static func level(for event: DispatchSource.MemoryPressureEvent) -> RuntimeMemoryPressureLevel {
        // Dispatch sources coalesce transitions. A delivered `.normal` bit is
        // the recovery edge and must win over stale warning/critical bits that
        // accumulated before the handler ran.
        if event.contains(.normal) {
            return .normal
        }
        if event.contains(.critical) {
            return .critical
        }
        return .warning
    }

    static func plan(for level: RuntimeMemoryPressureLevel) -> RuntimeMemoryPressurePlan {
        switch level {
        case .warning, .critical:
            return RuntimeMemoryPressurePlan(suspendOptionalWork: true, performRecovery: false)
        case .normal:
            return RuntimeMemoryPressurePlan(suspendOptionalWork: false, performRecovery: true)
        }
    }
}

struct RuntimeMemoryPressureEventGate {
    private(set) var latestSequence: UInt64 = 0

    mutating func accept(sequence: UInt64) -> Bool {
        guard sequence > latestSequence else { return false }
        latestSequence = sequence
        return true
    }
}

@MainActor
final class RuntimeMemoryPressureTransitionQueue {
    private var eventGate = RuntimeMemoryPressureEventGate()
    private var tailTask: Task<Void, Never>?

    var latestSequence: UInt64 { eventGate.latestSequence }

    @discardableResult
    func enqueue(
        sequence: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard eventGate.accept(sequence: sequence) else { return false }
        let previousTask = tailTask
        tailTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard self?.latestSequence == sequence else { return }
            await operation()
        }
        return true
    }

    func waitForIdle() async {
        await tailTask?.value
    }
}

/// Tracks non-persisted work such as model management, warm-up, standalone
/// retranscription, and re-enhancement that a hard-stall relaunch must not interrupt.
@MainActor
final class RuntimeProtectedWorkActivity: ObservableObject {
    static let shared = RuntimeProtectedWorkActivity()

    @Published private(set) var activeOperationCount = 0
    private var activeOperations: Set<UUID> = []

    var isBusy: Bool { !activeOperations.isEmpty }

    private init() {}

    @discardableResult
    func begin() -> UUID {
        let operationID = UUID()
        activeOperations.insert(operationID)
        activeOperationCount = activeOperations.count
        return operationID
    }

    func end(_ operationID: UUID) {
        activeOperations.remove(operationID)
        activeOperationCount = activeOperations.count
    }
}

/// Coordinates recovery of process-local resources that can become stale when
/// macOS resumes the process or restarts services under system pressure.
@MainActor
final class RuntimeRecoveryCoordinator {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RuntimeRecovery")
    private let recordingShortcutManager: RecordingShortcutManager
    private let cloudSpeechPreconnectionService: CloudSpeechPreconnectionService
    private let prewarmService: ModelPrewarmService
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var criticalWorkObserver: AnyCancellable?
    private var recoveryTask: Task<Void, Never>?
    private var pendingReasons = Set<RuntimeRecoveryReason>()
    private var recoveryEpoch: UInt64 = 0
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private let memoryPressureEventSequence = ManagedAtomic<UInt64>(0)
    private let memoryPressureTransitions = RuntimeMemoryPressureTransitionQueue()
    private var livenessMonitor: MainThreadLivenessMonitor?
    private var appKitEventProbe: AppKitEventProbe?

    init(
        engine: VoiceInkEngine,
        recordingShortcutManager: RecordingShortcutManager,
        cloudSpeechPreconnectionService: CloudSpeechPreconnectionService,
        prewarmService: ModelPrewarmService
    ) {
        self.recordingShortcutManager = recordingShortcutManager
        self.cloudSpeechPreconnectionService = cloudSpeechPreconnectionService
        self.prewarmService = prewarmService

        setupLifecycleObservers()
        setupMemoryPressureMonitoring()
        let initialCriticalWork = engine.recordingState != .idle
            || AudioTranscriptionManager.shared.hasQueuedWork
            || UpdateManager.shared.isBusy
            || engine.assistantSession.isBusy
            || RuntimeProtectedWorkActivity.shared.isBusy
        setupLivenessMonitoring(isCriticalWorkActive: initialCriticalWork)
        let appWork = Publishers.CombineLatest4(
            engine.$recordingState,
            AudioTranscriptionManager.shared.$hasQueuedWork,
            UpdateManager.shared.$activity,
            engine.assistantSession.$phase
        ).map { recordingState, hasQueuedAudioFiles, updateActivity, assistantPhase in
            recordingState != .idle || hasQueuedAudioFiles || updateActivity.isBusy
                    || assistantPhase == .responding || assistantPhase == .sendingFollowUp
        }
        criticalWorkObserver = appWork.combineLatest(RuntimeProtectedWorkActivity.shared.$activeOperationCount)
            .sink { [weak self] isAppWorkActive, modelOperationCount in
                self?.livenessMonitor?.setCriticalWorkActive(isAppWorkActive || modelOperationCount > 0)
        }
    }

    deinit {
        recoveryTask?.cancel()
        criticalWorkObserver?.cancel()
        memoryPressureSource?.cancel()
        livenessMonitor?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func simulateRecovery(reason: RuntimeRecoveryReason) {
        requestRecovery(reason)
    }

    private func setupLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceReasons: [(Notification.Name, RuntimeRecoveryReason)] = [
            (NSWorkspace.didWakeNotification, .systemWake),
            (NSWorkspace.screensDidWakeNotification, .screenWake),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        ]
        for (name, reason) in workspaceReasons {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.requestRecovery(reason)
                    }
                }
            )
        }

    }

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "com.prakashjoshipax.voiceink.runtime-pressure", qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let data = source?.data else { return }
            guard let self else { return }
            let sequence = self.memoryPressureEventSequence.wrappingIncrementThenLoad(ordering: .relaxed)
            Task { @MainActor [weak self] in
                self?.enqueueMemoryPressure(data, sequence: sequence)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func enqueueMemoryPressure(
        _ event: DispatchSource.MemoryPressureEvent,
        sequence: UInt64
    ) {
        guard memoryPressureTransitions.enqueue(
            sequence: sequence,
            operation: { [weak self] in
                await self?.handleMemoryPressure(event)
            }
        ) else {
            logger.notice("Discarded stale runtime memory-pressure transition sequence=\(sequence, privacy: .public)")
            return
        }
    }

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) async {
        let level = RuntimeMemoryPressurePolicy.level(for: event)
        let plan = RuntimeMemoryPressurePolicy.plan(for: level)
        if plan.suspendOptionalWork {
            logger.warning(
                "Runtime memory pressure increased critical=\(event.contains(.critical), privacy: .public)"
            )
            cloudSpeechPreconnectionService.setMemoryPressure(true)
            await prewarmService.suspendForRuntimePressure()
            return
        }

        if plan.performRecovery {
            logger.notice("Runtime memory pressure returned to normal")
            prewarmService.resumeAfterRuntimePressure()
            cloudSpeechPreconnectionService.setMemoryPressure(false)
            requestRecovery(.memoryPressureRecovered)
        }
    }

    private func setupLivenessMonitoring(isCriticalWorkActive: Bool) {
        let relaunchPlan = RuntimeRecoveryRelauncher.prepareIfAllowed()
        let eventProbe = AppKitEventProbe()
        let monitor = MainThreadLivenessMonitor(
            softStallThreshold: RuntimeRecoveryPolicy.softStallThreshold,
            hardStallThreshold: RuntimeRecoveryPolicy.hardStallThreshold,
            clockDiscontinuityThreshold: RuntimeRecoveryPolicy.clockDiscontinuityThreshold,
            onProbeRequested: { [weak eventProbe] in
                Task { @MainActor [weak eventProbe] in
                    eventProbe?.requestProbe()
                }
            },
            onClockDiscontinuity: { [weak self] gap, criticalWork in
                RuntimeRecoveryDiagnostics.record(
                    kind: "clockDiscontinuity",
                    duration: gap,
                    isCriticalWorkActive: criticalWork
                )
                Task { @MainActor [weak self] in
                    self?.requestRecovery(.clockDiscontinuity)
                }
            },
            onSoftStall: { duration, criticalWork in
                RuntimeRecoveryDiagnostics.record(
                    kind: "mainThreadStall",
                    duration: duration,
                    isCriticalWorkActive: criticalWork
                )
            },
            onHardStall: { duration, shouldProceed in
                let canRelaunch = shouldProceed() && relaunchPlan?.canRelaunch() == true
                RuntimeRecoveryDiagnostics.record(
                    kind: canRelaunch ? "automaticRelaunch" : "hardStallRelaunchUnavailable",
                    duration: duration,
                    isCriticalWorkActive: false
                )
                if canRelaunch {
                    return relaunchPlan?.launchAndExit(shouldProceed: shouldProceed) ?? false
                }
                return false
            }
        )
        eventProbe.onAcknowledged = { [weak monitor] in
            monitor?.acknowledgeAppKitEvent()
        }
        monitor.setCriticalWorkActive(isCriticalWorkActive)
        monitor.start()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak monitor] _ in
                monitor?.disarmPermanently()
            }
        )
        livenessMonitor = monitor
        appKitEventProbe = eventProbe
    }

    private func requestRecovery(_ reason: RuntimeRecoveryReason) {
        pendingReasons.insert(reason)
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            await self?.performRecovery()
        }
    }

    private func performRecovery() async {
        guard !pendingReasons.isEmpty else { return }
        recoveryEpoch &+= 1
        let reasons = pendingReasons.map(\.rawValue).sorted().joined(separator: ",")
        pendingReasons.removeAll()
        recoveryTask = nil

        logger.notice(
            "Runtime recovery started epoch=\(self.recoveryEpoch, privacy: .public) reasons=\(reasons, privacy: .public)"
        )
        let shortcutsRecovered = await recordingShortcutManager.recoverRuntimeMonitoring()
        cloudSpeechPreconnectionService.recoverAfterRuntimeInterruption()
        AppShortcuts.updateAppShortcutParameters()
        prewarmService.recoverAfterRuntimeInterruption()
        logger.notice(
            "Runtime recovery completed epoch=\(self.recoveryEpoch, privacy: .public) shortcutsRecovered=\(shortcutsRecovered, privacy: .public)"
        )
    }
}

final class MainThreadLivenessMonitor: @unchecked Sendable {
    typealias Clock = @Sendable () -> UInt64

    private let softStallNanoseconds: UInt64
    private let hardStallNanoseconds: UInt64
    private let clockDiscontinuityNanoseconds: UInt64
    private let clock: Clock
    private let onProbeRequested: @Sendable () -> Void
    private let onClockDiscontinuity: @Sendable (TimeInterval, Bool) -> Void
    private let onSoftStall: @Sendable (TimeInterval, Bool) -> Void
    private let onHardStall: @Sendable (TimeInterval, @escaping @Sendable () -> Bool) -> Bool
    private let lastMainAcknowledgement = ManagedAtomic<UInt64>(0)
    private let lastTimerTick = ManagedAtomic<UInt64>(0)
    private let isCriticalWorkActive = ManagedAtomic(false)
    private let hasAcknowledgedAppKitEvent = ManagedAtomic(false)
    private let isAppKitProbeOutstanding = ManagedAtomic(false)
    private let isPermanentlyDisarmed = ManagedAtomic(false)
    private let didReportSoftStall = ManagedAtomic(false)
    private let didHandleHardStall = ManagedAtomic(false)
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.main-thread-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(
        softStallThreshold: TimeInterval,
        hardStallThreshold: TimeInterval,
        clockDiscontinuityThreshold: TimeInterval,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        onProbeRequested: @escaping @Sendable () -> Void = {},
        onClockDiscontinuity: @escaping @Sendable (TimeInterval, Bool) -> Void,
        onSoftStall: @escaping @Sendable (TimeInterval, Bool) -> Void,
        onHardStall: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Bool) -> Bool
    ) {
        self.softStallNanoseconds = Self.nanoseconds(softStallThreshold)
        self.hardStallNanoseconds = Self.nanoseconds(hardStallThreshold)
        self.clockDiscontinuityNanoseconds = Self.nanoseconds(clockDiscontinuityThreshold)
        self.clock = clock
        self.onProbeRequested = onProbeRequested
        self.onClockDiscontinuity = onClockDiscontinuity
        self.onSoftStall = onSoftStall
        self.onHardStall = onHardStall
    }

    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let now = clock()
        lastMainAcknowledgement.store(now, ordering: .releasing)
        lastTimerTick.store(now, ordering: .releasing)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func disarmPermanently() {
        isPermanentlyDisarmed.store(true, ordering: .releasing)
        stop()
    }

    func setCriticalWorkActive(_ active: Bool) {
        isCriticalWorkActive.store(active, ordering: .releasing)
    }

    func acknowledgeAppKitEvent(now: UInt64? = nil) {
        lastMainAcknowledgement.store(now ?? clock(), ordering: .releasing)
        hasAcknowledgedAppKitEvent.store(true, ordering: .releasing)
        isAppKitProbeOutstanding.store(false, ordering: .releasing)
        didReportSoftStall.store(false, ordering: .releasing)
        didHandleHardStall.store(false, ordering: .releasing)
    }

    /// Test seam for deterministic fault simulation without blocking the test runner.
    func simulateTick(now: UInt64, enqueueMainProbe: Bool = false) {
        evaluate(now: now, enqueueMainProbe: enqueueMainProbe)
    }

    private func tick() {
        evaluate(now: clock(), enqueueMainProbe: true)
    }

    private func evaluate(now: UInt64, enqueueMainProbe: Bool) {
        guard !isPermanentlyDisarmed.load(ordering: .acquiring) else { return }
        let previousTick = lastTimerTick.exchange(now, ordering: .acquiringAndReleasing)
        if previousTick > 0 {
            let gap = now &- previousTick
            if gap >= clockDiscontinuityNanoseconds {
                // A sleeping or frozen process has not demonstrated a main-thread
                // hang. Give AppKit a fresh acknowledgement window after resume
                // instead of immediately escalating an hours-long timer gap.
                lastMainAcknowledgement.store(now, ordering: .releasing)
                didReportSoftStall.store(false, ordering: .releasing)
                didHandleHardStall.store(false, ordering: .releasing)
                let criticalWork = isCriticalWorkActive.load(ordering: .acquiring)
                onClockDiscontinuity(Self.seconds(gap), criticalWork)
                requestProbeIfNeeded(enqueueMainProbe)
                return
            }
        }

        requestProbeIfNeeded(enqueueMainProbe)

        // App construction can legitimately occupy the main actor before
        // AppKit begins dispatching events. Arm hang escalation only after a
        // posted probe has made one complete trip through the event loop.
        guard hasAcknowledgedAppKitEvent.load(ordering: .acquiring) else { return }

        let lastAcknowledgement = lastMainAcknowledgement.load(ordering: .acquiring)
        guard lastAcknowledgement > 0, now >= lastAcknowledgement else { return }
        let stall = now - lastAcknowledgement
        let criticalWork = isCriticalWorkActive.load(ordering: .acquiring)
        if stall >= softStallNanoseconds,
            didReportSoftStall.compareExchange(
                expected: false,
                desired: true,
                ordering: .acquiringAndReleasing
            ).exchanged
        {
            onSoftStall(Self.seconds(stall), criticalWork)
        }

        if RuntimeRecoveryPolicy.shouldRelaunch(
            stallDuration: Self.seconds(stall),
            isCriticalWorkActive: criticalWork
        ), !didHandleHardStall.load(ordering: .acquiring)
        {
            let shouldProceed: @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return !self.isPermanentlyDisarmed.load(ordering: .acquiring)
                    && !self.isCriticalWorkActive.load(ordering: .acquiring)
                    && self.lastMainAcknowledgement.load(ordering: .acquiring) == lastAcknowledgement
            }
            if shouldProceed(), onHardStall(Self.seconds(stall), shouldProceed) {
                didHandleHardStall.store(true, ordering: .releasing)
            }
        }
    }

    private func requestProbeIfNeeded(_ shouldEnqueue: Bool) {
        guard shouldEnqueue else { return }
        guard isAppKitProbeOutstanding.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        onProbeRequested()
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private static func seconds(_ nanoseconds: UInt64) -> TimeInterval {
        TimeInterval(nanoseconds) / 1_000_000_000
    }
}

/// A main-queue block alone cannot prove that AppKit is consuming UI events.
/// This probe posts a private application-defined event and acknowledges it
/// only after NSApplication dispatches it through the local event monitor.
@MainActor
final class AppKitEventProbe {
    static let eventSubtype = Int16(22_089)
    private var monitor: Any?
    private var sequence: Int = 0
    var onAcknowledged: (() -> Void)?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            self?.handleDispatchedEvent(event) ?? event
        }
    }

    /// Handles the event after AppKit dispatches it to the local monitor. Kept
    /// separate from event-queue pumping so the dispatch boundary can be
    /// simulated deterministically on both native and Rosetta test runners.
    func handleDispatchedEvent(_ event: NSEvent) -> NSEvent? {
        guard event.subtype.rawValue == Self.eventSubtype else { return event }
        onAcknowledged?()
        return nil
    }

    func requestProbe() {
        sequence &+= 1
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: Self.eventSubtype,
            data1: sequence,
            data2: 0
        ) else {
            return
        }
        NSApplication.shared.postEvent(event, atStart: false)
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        onAcknowledged = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}

private enum RuntimeRecoveryDiagnostics {
    private struct Incident: Codable {
        let timestamp: Date
        let kind: String
        let duration: TimeInterval
        let isCriticalWorkActive: Bool
        let processIdentifier: Int32
        let appVersion: String
        let buildNumber: String
    }

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RuntimeRecovery")

    static func record(kind: String, duration: TimeInterval, isCriticalWorkActive: Bool) {
        let incident = Incident(
            timestamp: Date(),
            kind: kind,
            duration: duration,
            isCriticalWorkActive: isCriticalWorkActive,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
        do {
            let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/VoiceInk", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder.voiceInkRecovery.encode(incident)
            try data.write(to: directory.appendingPathComponent("runtime-recovery-latest.json"), options: .atomic)
            logger.error(
                "Runtime recovery incident kind=\(kind, privacy: .public) duration=\(duration, format: .fixed(precision: 3), privacy: .public)s criticalWork=\(isCriticalWorkActive, privacy: .public)"
            )
        } catch {
            logger.error("Failed to persist runtime recovery incident: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static var voiceInkRecovery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct RuntimeRecoveryRelaunchPlan: Sendable {
    let helperURL: URL
    let appURL: URL
    let markerURL: URL
    let logURL: URL
    let cooldown: TimeInterval

    func canRelaunch(now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: markerURL.path),
            let modified = attributes[.modificationDate] as? Date
        else {
            return true
        }
        return now.timeIntervalSince(modified) >= cooldown
    }

    func launchAndExit(
        processExecutableURL: URL? = nil,
        shouldProceed: @escaping @Sendable () -> Bool = { true }
    ) -> Bool {
        guard canRelaunch(), shouldProceed() else { return false }
        do {
            try Data(Date().ISO8601Format().utf8).write(to: markerURL, options: .atomic)
            let process = Process()
            process.executableURL = processExecutableURL ?? helperURL
            process.arguments = [
                String(ProcessInfo.processInfo.processIdentifier),
                appURL.path,
                logURL.path,
            ]
            guard shouldProceed() else {
                try? FileManager.default.removeItem(at: markerURL)
                return false
            }
            try process.run()
            guard shouldProceed() else {
                process.terminate()
                try? FileManager.default.removeItem(at: markerURL)
                return false
            }
            Darwin._exit(70)
        } catch {
            // A failed spawn did not relaunch anything. Remove the marker so
            // the still-running watchdog can retry on its next tick.
            try? FileManager.default.removeItem(at: markerURL)
            Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RuntimeRecovery").fault(
                "Failed to launch runtime recovery helper: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

enum RuntimeRecoveryRelauncher {
    static let cooldown: TimeInterval = 10 * 60

    static func prepareIfAllowed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appURL: URL = Bundle.main.bundleURL,
        cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        libraryDirectory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    ) -> RuntimeRecoveryRelaunchPlan? {
        guard environment["XCTestConfigurationFilePath"] == nil,
            environment["VOICEINK_DISABLE_HANG_RECOVERY"] != "1",
            appURL.pathExtension == "app",
            let cachesDirectory,
            let libraryDirectory
        else {
            return nil
        }

        let root = cachesDirectory.appendingPathComponent("VoiceInk/RuntimeRecovery", isDirectory: true)
        let marker = root.appendingPathComponent("last-automatic-relaunch")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let helper = root.appendingPathComponent("relaunch-after-hang.zsh")
            try Data(helperScript.utf8).write(to: helper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let logDirectory = libraryDirectory.appendingPathComponent("Logs/VoiceInk", isDirectory: true)
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return RuntimeRecoveryRelaunchPlan(
                helperURL: helper,
                appURL: appURL.standardizedFileURL,
                markerURL: marker,
                logURL: logDirectory.appendingPathComponent("runtime-recovery.log"),
                cooldown: cooldown
            )
        } catch {
            Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RuntimeRecovery").error(
                "Failed to prepare runtime recovery helper: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static let helperScript = """
        #!/bin/zsh
        set -u
        old_pid="$1"
        app_path="$2"
        log_file="$3"
        exec >>"$log_file" 2>&1

        for attempt in {1..100}; do
          if ! /bin/kill -0 "$old_pid" 2>/dev/null; then
            /usr/bin/open -n "$app_path"
            exit $?
          fi
          /bin/sleep 0.1
        done
        exit 1
        """
}
