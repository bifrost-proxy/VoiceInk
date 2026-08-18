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

    func makeRequest() -> URLRequest {
        switch self {
        case .doubao(let apiKey, let resourceID, let endpoint):
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 10
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
            return request
        case .aliyun(let apiKey, let endpoint):
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 10
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("VoiceInk/macOS", forHTTPHeaderField: "User-Agent")
            return request
        }
    }
}

protocol CloudSpeechWebSocketConnection: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async throws
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
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: target.makeRequest())
        let connection = URLSessionCloudSpeechWebSocketConnection(session: session, task: task)
        task.resume()

        do {
            try await delegate.waitUntilOpen(timeout: 10)
            return connection
        } catch {
            connection.close()
            throw error
        }
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

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
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
    struct Snapshot: Sendable {
        let targetCount: Int
        let readyKeys: Set<CloudSpeechConnectionKey>
        let connectingKeys: Set<CloudSpeechConnectionKey>
        let dormantKeys: Set<CloudSpeechConnectionKey>
    }

    static let shared = CloudSpeechConnectionPool()

    private let connector: any CloudSpeechWebSocketConnecting
    private let idleTimeout: Duration
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CloudSpeechPreconnection")
    private var targets: [CloudSpeechConnectionKey: CloudSpeechConnectionTarget] = [:]
    private var generations: [CloudSpeechConnectionKey: UUID] = [:]
    private var readyConnections: [CloudSpeechConnectionKey: any CloudSpeechWebSocketConnection] = [:]
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
        idleTimeout: Duration = .seconds(30 * 60)
    ) {
        self.connector = connector
        self.idleTimeout = idleTimeout
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
        guard let connection = readyConnections.removeValue(forKey: key) else {
            let state = dormantKeys.contains(key) ? "dormant" : (connectTasks[key] != nil ? "connecting" : "notReady")
            logger.notice(
                "Cloud speech keep-alive lease miss reason=\(state, privacy: .public) suspended=\(self.isSuspended, privacy: .public) \(key.diagnosticLabel, privacy: .public)"
            )
            return nil
        }

        healthTasks.removeValue(forKey: key)?.cancel()
        generations[key] = UUID()
        ensureConnecting(for: key)
        logger.notice("Cloud speech keep-alive lease hit source=preconnected \(key.diagnosticLabel, privacy: .public)")
        return connection
    }

    func recordUseCompleted(for target: CloudSpeechConnectionTarget) {
        guard targets[target.key] == target else { return }
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
                invalidateConnectionWork(for: key)
            }
        } else {
            for key in targets.keys {
                ensureConnecting(for: key)
            }
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
            dormantKeys: dormantKeys
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
        failureCounts[key] = 0
        readyConnections[key]?.close()
        readyConnections[key] = connection
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
        readyConnections.removeValue(forKey: key)?.close()
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
        healthTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                do {
                    try await connection.ping()
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

    private func scheduleRetry(for key: CloudSpeechConnectionKey, generation: UUID) {
        guard retryTasks[key] == nil, targets[key] != nil, !dormantKeys.contains(key),
            !isSuspended, !isShuttingDown
        else { return }
        let failureCount = (failureCounts[key] ?? 0) + 1
        failureCounts[key] = failureCount
        let exponentialDelay = min(0.5 * pow(2, Double(max(0, failureCount - 1))), 30)
        let delay = exponentialDelay + Double.random(in: 0...0.25)
        logger.notice(
            "Cloud speech keep-alive retry scheduled nextAttempt=\(failureCount + 1, privacy: .public) delay=\(delay, format: .fixed(precision: 3), privacy: .public)s \(key.diagnosticLabel, privacy: .public)"
        )

        retryTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
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
        invalidateConnectionWork(for: key)
        logger.notice(
            "Cloud speech keep-alive paused reason=idleTimeout \(key.diagnosticLabel, privacy: .public)"
        )
    }

    private func invalidateConnectionWork(for key: CloudSpeechConnectionKey) {
        generations[key] = UUID()
        readyConnections.removeValue(forKey: key)?.close()
        connectTasks.removeValue(forKey: key)?.cancel()
        retryTasks.removeValue(forKey: key)?.cancel()
        healthTasks.removeValue(forKey: key)?.cancel()
        failureCounts[key] = 0
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
    private var isSleeping = false
    private var isNetworkAvailable = true
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
        let suspended = isSleeping || !isNetworkAvailable
        logger.notice(
            "Cloud speech keep-alive runtime state suspended=\(suspended, privacy: .public) sleeping=\(self.isSleeping, privacy: .public) pathAvailable=\(self.isNetworkAvailable, privacy: .public)"
        )
        Task { [pool] in
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
