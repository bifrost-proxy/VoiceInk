import AppKit
import Combine
import Foundation
import Network
import os

enum CloudSpeechConnectionKey: Hashable, Sendable {
    case doubao(endpoint: String, resourceID: String)
    case aliyun(endpoint: String)

    var providerLabel: String {
        switch self {
        case .doubao: "Doubao"
        case .aliyun: "Alibaba Cloud Qwen"
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .doubao(let endpoint, let resourceID):
            let host = URL(string: endpoint)?.host ?? "invalid-endpoint"
            return "provider=Doubao endpoint=\(host) resourceID=\(resourceID)"
        case .aliyun(let endpoint):
            let host = URL(string: endpoint)?.host ?? "invalid-endpoint"
            return "provider=AlibabaCloudQwen endpoint=\(host)"
        }
    }
}

enum CloudSpeechConnectionTarget: Equatable, @unchecked Sendable {
    case doubao(apiKey: String, resourceID: String, endpoint: URL)
    case aliyun(apiKey: String, endpoint: URL)

    var key: CloudSpeechConnectionKey {
        switch self {
        case .doubao(_, let resourceID, let endpoint):
            .doubao(endpoint: endpoint.absoluteString, resourceID: resourceID)
        case .aliyun(_, let endpoint):
            .aliyun(endpoint: endpoint.absoluteString)
        }
    }

    var openTimeout: TimeInterval {
        switch self {
        case .doubao: 4
        case .aliyun: 10
        }
    }

    func makeRequest() -> URLRequest {
        switch self {
        case .doubao(let apiKey, let resourceID, let endpoint):
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = openTimeout
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
            return request
        case .aliyun(let apiKey, let endpoint):
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = openTimeout
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("VoiceInk/macOS", forHTTPHeaderField: "User-Agent")
            return request
        }
    }
}

protocol CloudSpeechWebSocketConnection: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping(timeout: Duration) async throws
    func responseHeader(named name: String) -> String?
    func close()
}

extension CloudSpeechWebSocketConnection {
    func responseHeader(named _: String) -> String? { nil }
}

protocol CloudSpeechWebSocketConnecting: Sendable {
    func open(
        target: CloudSpeechConnectionTarget,
        onClosed: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection
}

struct URLSessionCloudSpeechWebSocketConnector: CloudSpeechWebSocketConnecting {
    func open(
        target: CloudSpeechConnectionTarget,
        onClosed: (@Sendable (Error?) -> Void)? = nil
    ) async throws -> any CloudSpeechWebSocketConnection {
        let delegate = CloudSpeechWebSocketDelegate(onClosed: onClosed)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = target.openTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: target.makeRequest())
        let connection = URLSessionCloudSpeechWebSocketConnection(session: session, task: task)
        task.resume()

        return try await withTaskCancellationHandler {
            do {
                try await delegate.waitUntilOpen(timeout: target.openTimeout)
                try Task.checkCancellation()
                return connection
            } catch {
                connection.close()
                throw error
            }
        } onCancel: {
            connection.close()
        }
    }
}

final class CloudSpeechPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func resolve(error: Error?) {
        lock.lock()
        guard let completion else {
            lock.unlock()
            return
        }
        self.completion = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()

        if let error {
            completion(.failure(error))
        } else {
            completion(.success(()))
        }
    }

    func scheduleTimeout(after timeout: Duration) {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.resolve(error: StreamingTranscriptionError.timeout)
        }

        lock.lock()
        if completion == nil {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask?.cancel()
        timeoutTask = task
        lock.unlock()
    }
}

private final class URLSessionCloudSpeechWebSocketConnection: CloudSpeechWebSocketConnection,
    @unchecked Sendable
{
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var isClosed = false

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func ping(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = CloudSpeechPingCompletion { result in
                continuation.resume(with: result)
            }
            task.sendPing { error in
                completion.resolve(error: error)
            }
            completion.scheduleTimeout(after: timeout)
        }
    }

    func responseHeader(named name: String) -> String? {
        guard let response = task.response as? HTTPURLResponse else { return nil }
        return response.value(forHTTPHeaderField: name)
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

private final class CloudSpeechWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResult: Result<Void, Error>?
    private var didOpen = false
    private var didNotifyClosed = false
    private let onClosed: (@Sendable (Error?) -> Void)?

    init(onClosed: (@Sendable (Error?) -> Void)?) {
        self.onClosed = onClosed
    }

    func waitUntilOpen(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let openResult {
                lock.unlock()
                continuation.resume(with: openResult)
                return
            }
            openContinuation = continuation
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finishOpen(.failure(StreamingTranscriptionError.timeout))
            }
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        lock.lock()
        didOpen = true
        lock.unlock()
        finishOpen(.success(()))
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason _: Data?
    ) {
        notifyClosed(
            NSError(
                domain: "CloudSpeechWebSocket",
                code: Int(closeCode.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "WebSocket closed (\(closeCode.rawValue))"]
            )
        )
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasOpen = didOpen
        lock.unlock()

        if !wasOpen, let error {
            finishOpen(.failure(error))
        }
        if wasOpen || error != nil {
            notifyClosed(error)
        }
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        lock.lock()
        guard openResult == nil else {
            lock.unlock()
            return
        }
        openResult = result
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func notifyClosed(_ error: Error?) {
        lock.lock()
        guard !didNotifyClosed else {
            lock.unlock()
            return
        }
        didNotifyClosed = true
        let callback = onClosed
        lock.unlock()
        callback?(error)
    }
}

actor CloudSpeechConnectionPool {
    private struct ReadyConnection: Sendable {
        let connection: any CloudSpeechWebSocketConnection
        let openedAt: ContinuousClock.Instant
    }

    struct Snapshot: Sendable {
        let targetCount: Int
        let readyKeys: Set<CloudSpeechConnectionKey>
        let connectingKeys: Set<CloudSpeechConnectionKey>
        let dormantKeys: Set<CloudSpeechConnectionKey>
        let retryingKeys: Set<CloudSpeechConnectionKey>
        let failureCounts: [CloudSpeechConnectionKey: Int]
    }

    static let shared = CloudSpeechConnectionPool()

    private let connector: any CloudSpeechWebSocketConnecting
    private let idleTimeout: Duration
    private let maxStandbyAge: Duration
    private let leaseValidationTimeout: Duration
    private let healthCheckTimeout: Duration
    private let circuitBreakerFailureCount: Int
    private let circuitBreakerDelay: Duration
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CloudSpeechPreconnection")
    private var targets: [CloudSpeechConnectionKey: CloudSpeechConnectionTarget] = [:]
    private var generations: [CloudSpeechConnectionKey: UUID] = [:]
    private var readyConnections: [CloudSpeechConnectionKey: ReadyConnection] = [:]
    private var connectTasks: [CloudSpeechConnectionKey: Task<Void, Never>] = [:]
    private var retryTasks: [CloudSpeechConnectionKey: Task<Void, Never>] = [:]
    private var healthTasks: [CloudSpeechConnectionKey: Task<Void, Never>] = [:]
    private var idleTasks: [CloudSpeechConnectionKey: Task<Void, Never>] = [:]
    private var activityTokens: [CloudSpeechConnectionKey: UUID] = [:]
    private var dormantKeys: Set<CloudSpeechConnectionKey> = []
    private var failureCounts: [CloudSpeechConnectionKey: Int] = [:]
    private var isSuspended = false
    private var isShuttingDown = false

    init(
        connector: any CloudSpeechWebSocketConnecting = URLSessionCloudSpeechWebSocketConnector(),
        idleTimeout: Duration = .seconds(30 * 60),
        maxStandbyAge: Duration = .seconds(5 * 60),
        leaseValidationTimeout: Duration = .milliseconds(750),
        healthCheckTimeout: Duration = .seconds(3),
        circuitBreakerFailureCount: Int = 5,
        circuitBreakerDelay: Duration = .seconds(5 * 60)
    ) {
        self.connector = connector
        self.idleTimeout = idleTimeout
        self.maxStandbyAge = maxStandbyAge
        self.leaseValidationTimeout = leaseValidationTimeout
        self.healthCheckTimeout = healthCheckTimeout
        self.circuitBreakerFailureCount = circuitBreakerFailureCount
        self.circuitBreakerDelay = circuitBreakerDelay
    }

    func reconcile(targets newTargets: [CloudSpeechConnectionTarget]) {
        guard !isShuttingDown else { return }
        let replacements = Dictionary(uniqueKeysWithValues: newTargets.map { ($0.key, $0) })

        for key in Set(targets.keys).subtracting(replacements.keys) {
            logger.notice("Cloud speech keep-alive target removed \(key.diagnosticLabel, privacy: .public)")
            removeSlot(for: key)
        }

        for (key, target) in replacements where targets[key] != target {
            removeSlot(for: key)
            targets[key] = target
            generations[key] = UUID()
            logger.notice("Cloud speech keep-alive target registered \(key.diagnosticLabel, privacy: .public)")
            recordActivity(for: key)
        }

        guard !isSuspended else { return }
        for key in replacements.keys {
            ensureConnecting(for: key)
        }
    }

    func lease(for target: CloudSpeechConnectionTarget) async -> (any CloudSpeechWebSocketConnection)? {
        let key = target.key
        guard targets[key] == target else {
            logger.notice(
                "Cloud speech keep-alive lease miss reason=targetNotRegistered \(key.diagnosticLabel, privacy: .public)"
            )
            return nil
        }
        recordActivity(for: key)
        guard let readyConnection = readyConnections.removeValue(forKey: key) else {
            let state = dormantKeys.contains(key) ? "dormant" : (connectTasks[key] != nil ? "connecting" : "notReady")
            logger.notice(
                "Cloud speech keep-alive lease miss reason=\(state, privacy: .public) suspended=\(self.isSuspended, privacy: .public) \(key.diagnosticLabel, privacy: .public)"
            )
            return nil
        }

        healthTasks.removeValue(forKey: key)?.cancel()
        generations[key] = UUID()
        let age = readyConnection.openedAt.duration(to: clock.now)
        guard age < maxStandbyAge else {
            readyConnection.connection.close()
            ensureConnecting(for: key)
            logger.notice(
                "Cloud speech keep-alive lease rejected reason=maxStandbyAge ageMs=\(Self.milliseconds(age), privacy: .public) \(key.diagnosticLabel, privacy: .public)"
            )
            return nil
        }

        let validationStartedAt = clock.now
        do {
            try await readyConnection.connection.ping(timeout: leaseValidationTimeout)
            let validationDuration = validationStartedAt.duration(to: clock.now)
            guard targets[key] == target, !isSuspended, !isShuttingDown else {
                readyConnection.connection.close()
                logger.notice(
                    "Cloud speech keep-alive lease rejected reason=poolStateChanged validationMs=\(Self.milliseconds(validationDuration), privacy: .public) \(key.diagnosticLabel, privacy: .public)"
                )
                return nil
            }
            logger.notice(
                "Cloud speech keep-alive lease hit source=preconnected validationMs=\(Self.milliseconds(validationDuration), privacy: .public) ageMs=\(Self.milliseconds(age), privacy: .public) \(key.diagnosticLabel, privacy: .public)"
            )
            failureCounts[key] = 0
            ensureConnecting(for: key)
            return readyConnection.connection
        } catch {
            readyConnection.connection.close()
            let validationDuration = validationStartedAt.duration(to: clock.now)
            logger.warning(
                "Cloud speech keep-alive lease rejected reason=validationFailed validationMs=\(Self.milliseconds(validationDuration), privacy: .public) ageMs=\(Self.milliseconds(age), privacy: .public) \(key.diagnosticLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            if let generation = generations[key] {
                scheduleRetry(for: key, generation: generation)
            }
            return nil
        }
    }

    func recordUseCompleted(for target: CloudSpeechConnectionTarget, successful: Bool) {
        guard targets[target.key] == target else { return }
        guard successful else {
            recordActivity(for: target.key)
            return
        }
        failureCounts[target.key] = 0
        retryTasks.removeValue(forKey: target.key)?.cancel()
        recordActivity(for: target.key)
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        logger.notice(
            "Cloud speech keep-alive suspension changed suspended=\(suspended, privacy: .public) targetCount=\(self.targets.count, privacy: .public)"
        )
        if suspended {
            for key in targets.keys {
                invalidateConnectionWork(for: key, preserveRetrySchedule: true, resetFailureCount: false)
            }
        } else {
            for key in targets.keys {
                ensureConnecting(for: key)
            }
        }
    }

    /// Invalidates process-local transports while retaining configured targets
    /// and their idle state, then recreates only the connections that should be
    /// active. This is used after sleep, session resume, or system-service
    /// interruption where an apparently open socket may refer to stale state.
    func recoverRuntimeConnections() {
        guard !isShuttingDown else { return }
        logger.notice(
            "Cloud speech keep-alive runtime recovery started targetCount=\(self.targets.count, privacy: .public) suspended=\(self.isSuspended, privacy: .public)"
        )
        for key in targets.keys {
            invalidateConnectionWork(for: key, preserveRetrySchedule: true, resetFailureCount: false)
        }
        guard !isSuspended else { return }
        for key in targets.keys where !dormantKeys.contains(key) {
            ensureConnecting(for: key)
        }
    }

    func shutdown() {
        isShuttingDown = true
        for key in Array(targets.keys) {
            removeSlot(for: key)
        }
        targets.removeAll()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            targetCount: targets.count,
            readyKeys: Set(readyConnections.keys),
            connectingKeys: Set(connectTasks.keys),
            dormantKeys: dormantKeys,
            retryingKeys: Set(retryTasks.keys),
            failureCounts: failureCounts
        )
    }

    private func ensureConnecting(for key: CloudSpeechConnectionKey) {
        guard !isSuspended, !isShuttingDown, !dormantKeys.contains(key), readyConnections[key] == nil,
            connectTasks[key] == nil, retryTasks[key] == nil,
            let target = targets[key]
        else {
            return
        }

        let generation = generations[key] ?? UUID()
        generations[key] = generation
        let connector = connector
        let attempt = (failureCounts[key] ?? 0) + 1
        let startedAt = Date()
        logger.notice(
            "Cloud speech keep-alive connect started attempt=\(attempt, privacy: .public) \(key.diagnosticLabel, privacy: .public)"
        )
        connectTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await connector.open(
                    target: target,
                    onClosed: { [weak self] error in
                        Task {
                            await self?.connectionClosed(for: key, generation: generation, error: error)
                        }
                    }
                )
                await self.connectionOpened(
                    connection,
                    for: key,
                    generation: generation,
                    attempt: attempt,
                    elapsed: Date().timeIntervalSince(startedAt)
                )
            } catch {
                await self.connectionFailed(
                    for: key,
                    generation: generation,
                    attempt: attempt,
                    elapsed: Date().timeIntervalSince(startedAt),
                    error: error
                )
            }
        }
    }

    private func connectionOpened(
        _ connection: any CloudSpeechWebSocketConnection,
        for key: CloudSpeechConnectionKey,
        generation: UUID,
        attempt: Int,
        elapsed: TimeInterval
    ) {
        guard generations[key] == generation, targets[key] != nil, !isSuspended, !isShuttingDown else {
            connection.close()
            return
        }

        connectTasks[key] = nil
        retryTasks.removeValue(forKey: key)?.cancel()
        readyConnections[key]?.connection.close()
        readyConnections[key] = ReadyConnection(connection: connection, openedAt: clock.now)
        startHealthChecks(for: key, generation: generation, connection: connection)
        logger.notice(
            "Cloud speech keep-alive connect ready attempt=\(attempt, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s \(key.diagnosticLabel, privacy: .public)"
        )
    }

    private func connectionFailed(
        for key: CloudSpeechConnectionKey,
        generation: UUID,
        attempt: Int,
        elapsed: TimeInterval,
        error: Error
    ) {
        guard generations[key] == generation, targets[key] != nil, !isSuspended, !isShuttingDown else { return }
        connectTasks[key] = nil
        logger.warning(
            "Cloud speech keep-alive connect failed attempt=\(attempt, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s \(key.diagnosticLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        scheduleRetry(for: key, generation: generation)
    }

    private func connectionClosed(
        for key: CloudSpeechConnectionKey,
        generation: UUID,
        source: String = "transportCallback",
        error: Error?
    ) {
        guard generations[key] == generation, targets[key] != nil, !isSuspended, !isShuttingDown else { return }
        readyConnections.removeValue(forKey: key)?.connection.close()
        healthTasks.removeValue(forKey: key)?.cancel()
        connectTasks[key] = nil
        let errorDescription = error?.localizedDescription ?? "none"
        logger.notice(
            "Cloud speech keep-alive standby closed source=\(source, privacy: .public) \(key.diagnosticLabel, privacy: .public) error=\(errorDescription, privacy: .public)"
        )
        scheduleRetry(for: key, generation: generation)
    }

    private func startHealthChecks(
        for key: CloudSpeechConnectionKey,
        generation: UUID,
        connection: any CloudSpeechWebSocketConnection
    ) {
        healthTasks[key]?.cancel()
        let healthCheckTimeout = healthCheckTimeout
        healthTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                do {
                    try await connection.ping(timeout: healthCheckTimeout)
                    await self?.connectionHealthCheckSucceeded(for: key, generation: generation)
                } catch {
                    await self?.connectionClosed(
                        for: key,
                        generation: generation,
                        source: "healthCheck",
                        error: error
                    )
                    return
                }
            }
        }
    }

    private func connectionHealthCheckSucceeded(for key: CloudSpeechConnectionKey, generation: UUID) {
        guard generations[key] == generation, readyConnections[key] != nil else { return }
        if failureCounts[key, default: 0] > 0 {
            logger.notice(
                "Cloud speech keep-alive failure history cleared after a successful health check \(key.diagnosticLabel, privacy: .public)"
            )
        }
        failureCounts[key] = 0
    }

    private func scheduleRetry(for key: CloudSpeechConnectionKey, generation: UUID) {
        guard retryTasks[key] == nil, targets[key] != nil, !dormantKeys.contains(key),
            !isSuspended, !isShuttingDown
        else { return }
        let failureCount = (failureCounts[key] ?? 0) + 1
        failureCounts[key] = failureCount
        let delay = Self.retryDelay(
            failureCount: failureCount,
            circuitBreakerFailureCount: circuitBreakerFailureCount,
            circuitBreakerDelay: circuitBreakerDelay,
            jitter: Double.random(in: 0...0.25)
        )
        logger.notice(
            "Cloud speech keep-alive retry scheduled nextAttempt=\(failureCount + 1, privacy: .public) delayMs=\(Self.milliseconds(delay), privacy: .public) circuitOpen=\((failureCount >= self.circuitBreakerFailureCount), privacy: .public) \(key.diagnosticLabel, privacy: .public)"
        )

        retryTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.retryConnection(for: key, generation: generation)
        }
    }

    private func retryConnection(for key: CloudSpeechConnectionKey, generation: UUID) {
        guard generations[key] == generation else { return }
        retryTasks[key] = nil
        ensureConnecting(for: key)
    }

    private func recordActivity(for key: CloudSpeechConnectionKey) {
        guard targets[key] != nil, !isShuttingDown else { return }
        let wasDormant = dormantKeys.remove(key) != nil
        let token = UUID()
        activityTokens[key] = token
        idleTasks.removeValue(forKey: key)?.cancel()
        let idleTimeout = idleTimeout
        idleTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.becomeDormant(for: key, activityToken: token)
        }
        if wasDormant {
            logger.notice("Cloud speech keep-alive resumed reason=activity \(key.diagnosticLabel, privacy: .public)")
        }
        ensureConnecting(for: key)
    }

    private func becomeDormant(for key: CloudSpeechConnectionKey, activityToken: UUID) {
        guard activityTokens[key] == activityToken, targets[key] != nil, !isShuttingDown else { return }
        activityTokens[key] = nil
        idleTasks[key] = nil
        dormantKeys.insert(key)
        invalidateConnectionWork(for: key, preserveRetrySchedule: true, resetFailureCount: false)
        logger.notice(
            "Cloud speech keep-alive paused reason=idleTimeout \(key.diagnosticLabel, privacy: .public)"
        )
    }

    private func invalidateConnectionWork(
        for key: CloudSpeechConnectionKey,
        preserveRetrySchedule: Bool = false,
        resetFailureCount: Bool = true
    ) {
        let keepsScheduledRetry = preserveRetrySchedule && retryTasks[key] != nil
        if !keepsScheduledRetry {
            generations[key] = UUID()
        }
        readyConnections.removeValue(forKey: key)?.connection.close()
        connectTasks.removeValue(forKey: key)?.cancel()
        if !keepsScheduledRetry {
            retryTasks.removeValue(forKey: key)?.cancel()
        }
        healthTasks.removeValue(forKey: key)?.cancel()
        if resetFailureCount {
            failureCounts[key] = 0
        }
    }

    private func removeSlot(for key: CloudSpeechConnectionKey) {
        invalidateConnectionWork(for: key)
        idleTasks.removeValue(forKey: key)?.cancel()
        activityTokens[key] = nil
        dormantKeys.remove(key)
        targets[key] = nil
        generations[key] = nil
        failureCounts[key] = nil
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let seconds = components.seconds * 1_000
        let milliseconds = components.attoseconds / 1_000_000_000_000_000
        return seconds + milliseconds
    }

    nonisolated static func retryDelay(
        failureCount: Int,
        circuitBreakerFailureCount: Int = 5,
        circuitBreakerDelay: Duration = .seconds(5 * 60),
        jitter: Double = 0
    ) -> Duration {
        guard failureCount < circuitBreakerFailureCount else { return circuitBreakerDelay }
        let exponentialDelay = min(0.5 * pow(2, Double(max(0, failureCount - 1))), 30)
        return .seconds(exponentialDelay + max(0, jitter))
    }
}

@MainActor
final class CloudSpeechPreconnectionService: ObservableObject {
    private let transcriptionModelManager: TranscriptionModelManager
    private let pool: CloudSpeechConnectionPool
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "CloudSpeechPreconnectionService"
    )
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.cloud-speech-path")
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var suspensionUpdateTask: Task<Void, Never>?
    private var isSleeping = false
    private var isNetworkAvailable = true
    private var isUnderMemoryPressure = false
    private var lastConfigurationSummary: String?

    init(
        transcriptionModelManager: TranscriptionModelManager,
        pool: CloudSpeechConnectionPool = .shared
    ) {
        self.transcriptionModelManager = transcriptionModelManager
        self.pool = pool
        setupObservers()
        setupNetworkMonitoring()
        scheduleRefresh(delay: .milliseconds(500))
    }

    deinit {
        refreshTask?.cancel()
        suspensionUpdateTask?.cancel()
        pathMonitor.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        Task { [pool] in
            await pool.shutdown()
        }
    }

    func refreshNow() {
        scheduleRefresh(delay: .zero)
    }

    func setMemoryPressure(_ pressured: Bool) {
        guard isUnderMemoryPressure != pressured else { return }
        isUnderMemoryPressure = pressured
        updateSuspension()
        if !pressured {
            scheduleRefresh(delay: .milliseconds(250))
        }
    }

    func recoverAfterRuntimeInterruption() {
        logger.notice("Rebuilding cloud speech connections after runtime interruption")
        Task { [pool] in
            await pool.recoverRuntimeConnections()
        }
        scheduleRefresh(delay: .milliseconds(250))
    }

    private func setupObservers() {
        let center = NotificationCenter.default
        let refreshNames: [Notification.Name] = [
            UserDefaults.didChangeNotification,
            .aiProviderKeyChanged,
            .cloudConfigurationDidChange,
            .didChangeModel,
            .modeConfigurationsDidChange,
        ]
        for name in refreshNames {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.scheduleRefresh(delay: .milliseconds(200))
                    }
                }
            )
        }

        observers.append(
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
                [pool] _ in
                Task {
                    await pool.shutdown()
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSleeping = true
                    self?.updateSuspension()
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSleeping = false
                    self?.updateSuspension()
                    self?.scheduleRefresh(delay: .milliseconds(250))
                }
            }
        )
    }

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isNetworkAvailable = path.status == .satisfied
                self?.updateSuspension()
                if path.status == .satisfied {
                    self?.scheduleRefresh(delay: .milliseconds(100))
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func updateSuspension() {
        let suspended = isSleeping || !isNetworkAvailable || isUnderMemoryPressure
        logger.notice(
            "Cloud speech keep-alive runtime state suspended=\(suspended, privacy: .public) sleeping=\(self.isSleeping, privacy: .public) pathAvailable=\(self.isNetworkAvailable, privacy: .public) memoryPressure=\(self.isUnderMemoryPressure, privacy: .public)"
        )
        let previousUpdate = suspensionUpdateTask
        suspensionUpdateTask = Task { [pool] in
            await previousUpdate?.value
            guard !Task.isCancelled else { return }
            await pool.setSuspended(suspended)
        }
    }

    private func scheduleRefresh(delay: Duration) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconcileTargets()
        }
    }

    private func reconcileTargets() {
        var targets: [CloudSpeechConnectionTarget] = []

        let doubaoSettings = DoubaoSpeechSettings.current()
        let doubaoAPIKey = APIKeyManager.shared.getAPIKey(forProvider: "Doubao Speech")
        var doubaoResourceCount = 0
        if doubaoSettings.keepConnectionReady,
            let apiKey = doubaoAPIKey,
            !apiKey.isEmpty
        {
            let resourceIDs = configuredDoubaoResourceIDs()
            doubaoResourceCount = resourceIDs.count
            targets.append(
                contentsOf: resourceIDs.map {
                    .doubao(
                        apiKey: apiKey,
                        resourceID: $0,
                        endpoint: DoubaoWebSocketSession.Endpoint.optimizedStreaming.url
                    )
                }
            )
        }

        let aliyunSettings = AliyunQwenSpeechSettings.current()
        let aliyunAPIKey = APIKeyManager.shared.getAPIKey(forProvider: AliyunQwenSpeechProvider.key)
        if aliyunSettings.keepConnectionReady,
            let apiKey = aliyunAPIKey,
            !apiKey.isEmpty,
            let endpoint = try? aliyunSettings.webSocketURL()
        {
            targets.append(.aliyun(apiKey: apiKey, endpoint: endpoint))
        }

        let summary = [
            "doubaoEnabled=\(doubaoSettings.keepConnectionReady)",
            "doubaoConfigured=\(!(doubaoAPIKey ?? "").isEmpty)",
            "doubaoResourceCount=\(doubaoResourceCount)",
            "aliyunEnabled=\(aliyunSettings.keepConnectionReady)",
            "aliyunConfigured=\(!(aliyunAPIKey ?? "").isEmpty)",
            "targetCount=\(targets.count)",
        ].joined(separator: " ")
        if summary != lastConfigurationSummary {
            lastConfigurationSummary = summary
            logger.notice("Cloud speech keep-alive configuration \(summary, privacy: .public)")
        }

        Task { [pool] in
            await pool.reconcile(targets: targets)
        }
    }

    private func configuredDoubaoResourceIDs() -> [String] {
        var resourceIDs = Set<String>()

        if let model = transcriptionModelManager.currentTranscriptionModel,
            model.provider == .doubaoSpeech
        {
            resourceIDs.insert(model.name)
        }

        let modelsByName = Dictionary(
            uniqueKeysWithValues: transcriptionModelManager.allAvailableModels.map { ($0.name, $0) }
        )
        for configuration in ModeManager.shared.enabledConfigurations where configuration.isRealtimeTranscriptionEnabled {
            guard let modelName = configuration.selectedTranscriptionModelName,
                let model = modelsByName[modelName],
                model.provider == .doubaoSpeech
            else {
                continue
            }
            resourceIDs.insert(model.name)
        }

        if resourceIDs.isEmpty {
            resourceIDs.insert(DoubaoSpeechProvider.defaultResourceID)
        }
        return resourceIDs.sorted()
    }
}
