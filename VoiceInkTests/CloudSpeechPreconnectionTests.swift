import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
struct CloudSpeechPreconnectionTests {
    @Test func providerTargetsKeepDoubaoAndAliyunConnectionsStrictlyIsolated() {
        let doubao = CloudSpeechConnectionTarget.doubao(
            apiKey: "doubao-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            endpoint: DoubaoWebSocketSession.Endpoint.optimizedStreaming.url
        )
        let aliyun = CloudSpeechConnectionTarget.aliyun(
            apiKey: "aliyun-key",
            endpoint: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
        )

        #expect(doubao.key != aliyun.key)
        #expect(doubao.makeRequest().url?.host == "openspeech.bytedance.com")
        #expect(doubao.openTimeout == 4)
        #expect(doubao.makeRequest().timeoutInterval == 4)
        #expect(
            doubao.makeRequest().value(forHTTPHeaderField: "X-Api-Resource-Id")
                == DoubaoSpeechProvider.defaultResourceID
        )
        #expect(doubao.makeRequest().value(forHTTPHeaderField: "Authorization") == nil)
        #expect(doubao.key.diagnosticLabel.contains("provider=Doubao"))
        #expect(doubao.key.diagnosticLabel.contains("endpoint=openspeech.bytedance.com"))
        #expect(doubao.key.diagnosticLabel.contains("resourceID=\(DoubaoSpeechProvider.defaultResourceID)"))
        #expect(!doubao.key.diagnosticLabel.contains("doubao-key"))
        #expect(aliyun.makeRequest().url?.host == "dashscope.aliyuncs.com")
        #expect(aliyun.openTimeout == 10)
        #expect(aliyun.makeRequest().timeoutInterval == 10)
        #expect(aliyun.makeRequest().value(forHTTPHeaderField: "X-Api-Resource-Id") == nil)
        #expect(aliyun.key.diagnosticLabel == "provider=AlibabaCloudQwen endpoint=dashscope.aliyuncs.com")
        #expect(!aliyun.key.diagnosticLabel.contains("aliyun-key"))
    }

    @Test func leasingAReadyConnectionImmediatelyBuildsAReplacement() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(connector: connector)
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        #expect(await connector.openCount == 1)

        let leased = await pool.lease(for: target)
        #expect(leased != nil)
        #expect(await connector.totalPingCount == 1)
        try await waitUntilReady(pool, key: target.key)
        #expect(await connector.openCount == 2)

        leased?.close()
        try await Task.sleep(for: .milliseconds(20))
        let snapshot = await pool.snapshot()
        #expect(snapshot.readyKeys == [target.key])

        await pool.shutdown()
        #expect(await connector.allConnectionsClosed)
    }

    @Test func failedLeaseValidationRejectsTheStaleConnectionAndBuildsAReplacement() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(connector: connector)
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await connector.failLatestConnectionPing()

        let leased = await pool.lease(for: target)
        #expect(leased == nil)
        try await waitUntilReady(pool, key: target.key)
        #expect(await connector.openCount == 2)
        #expect(await pool.snapshot().failureCounts[target.key] == 1)
        #expect(await connector.connection(at: 0)?.isClosed == true)

        await pool.shutdown()
    }

    @Test func overAgeStandbyConnectionIsNeverLeased() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(
            connector: connector,
            maxStandbyAge: .milliseconds(30)
        )
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        try await Task.sleep(for: .milliseconds(40))

        let leased = await pool.lease(for: target)
        #expect(leased == nil)
        #expect(await connector.totalPingCount == 0)
        try await waitUntilReady(pool, key: target.key)
        #expect(await connector.openCount == 2)

        await pool.shutdown()
    }

    @Test func disablingATargetClosesItsStandbyConnection() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(connector: connector)
        let target = CloudSpeechConnectionTarget.doubao(
            apiKey: "test-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            endpoint: DoubaoWebSocketSession.Endpoint.optimizedStreaming.url
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await pool.reconcile(targets: [])

        let snapshot = await pool.snapshot()
        #expect(snapshot.targetCount == 0)
        #expect(snapshot.readyKeys.isEmpty)
        #expect(await connector.allConnectionsClosed)
    }

    @Test func pingCompletionIgnoresDuplicateURLSessionCallbacks() {
        let probe = CloudSpeechPingCompletionProbe()
        let completion = CloudSpeechPingCompletion { result in
            probe.record(result)
        }

        completion.resolve(error: nil)
        completion.resolve(
            error: NSError(
                domain: NSPOSIXErrorDomain,
                code: 53,
                userInfo: [NSLocalizedDescriptionKey: "Software caused connection abort"]
            )
        )

        #expect(probe.completionCount == 1)
        #expect(probe.firstCompletionSucceeded)
    }

    @Test func pingCompletionFailsWhenTheValidationDeadlineExpires() async {
        let probe = CloudSpeechPingCompletionProbe()
        let completion = CloudSpeechPingCompletion { result in
            probe.record(result)
        }

        completion.scheduleTimeout(after: .milliseconds(10))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(probe.completionCount == 1)
        #expect(!probe.firstCompletionSucceeded)
    }

    @Test func standbyHandshakeDoesNotSendBusinessFrames() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(connector: connector)
        let target = CloudSpeechConnectionTarget.doubao(
            apiKey: "test-key",
            resourceID: DoubaoSpeechProvider.defaultResourceID,
            endpoint: DoubaoWebSocketSession.Endpoint.optimizedStreaming.url
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)

        #expect(await connector.totalSentMessages == 0)
        await pool.shutdown()
    }

    @Test func closedStandbyConnectionIsAutomaticallyReplaced() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(connector: connector)
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await connector.closeLatestConnection()

        for _ in 0..<200 {
            let snapshot = await pool.snapshot()
            if snapshot.readyKeys.contains(target.key), await connector.openCount == 2 {
                #expect(snapshot.failureCounts[target.key] == 1)
                await pool.recordUseCompleted(for: target, successful: true)
                #expect(await pool.snapshot().failureCounts[target.key] == 0)
                await pool.shutdown()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the replacement standby connection")
        await pool.shutdown()
    }

    @Test func runtimeRecoveryInvalidatesAndRebuildsActiveStandbyConnections() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(connector: connector)
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await pool.recoverRuntimeConnections()
        try await waitUntilReady(pool, key: target.key)

        #expect(await connector.openCount == 2)
        #expect(await connector.connection(at: 0)?.isClosed == true)
        await pool.shutdown()
    }

    @Test func retryPolicyOpensACircuitAfterRepeatedUnstableConnections() {
        #expect(
            CloudSpeechConnectionPool.retryDelay(failureCount: 1, jitter: 0)
                == .milliseconds(500)
        )
        #expect(
            CloudSpeechConnectionPool.retryDelay(failureCount: 4, jitter: 0)
                == .seconds(4)
        )
        #expect(
            CloudSpeechConnectionPool.retryDelay(failureCount: 5, jitter: 0)
                == .seconds(5 * 60)
        )
    }

    @Test func successfulUseCancelsAnOpenCircuitAndRestoresStandby() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(
            connector: connector,
            circuitBreakerFailureCount: 1,
            circuitBreakerDelay: .seconds(5 * 60)
        )
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await connector.closeLatestConnection()

        for _ in 0..<100 {
            if await pool.snapshot().retryingKeys.contains(target.key) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pool.snapshot().retryingKeys.contains(target.key))

        await pool.recordUseCompleted(for: target, successful: true)
        try await waitUntilReady(pool, key: target.key)
        let recoveredSnapshot = await pool.snapshot()
        #expect(await connector.openCount == 2)
        #expect(!recoveredSnapshot.retryingKeys.contains(target.key))
        await pool.shutdown()
    }

    @Test func failedUsePreservesAnOpenCircuit() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(
            connector: connector,
            circuitBreakerFailureCount: 1,
            circuitBreakerDelay: .seconds(5 * 60)
        )
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await connector.closeLatestConnection()

        for _ in 0..<100 {
            if await pool.snapshot().retryingKeys.contains(target.key) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await pool.recordUseCompleted(for: target, successful: false)
        try await Task.sleep(for: .milliseconds(20))

        let snapshot = await pool.snapshot()
        #expect(snapshot.failureCounts[target.key] == 1)
        #expect(snapshot.retryingKeys.contains(target.key))
        #expect(await connector.openCount == 1)
        await pool.shutdown()
    }

    @Test func runtimeRecoveryPreservesAnOpenCircuit() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(
            connector: connector,
            circuitBreakerFailureCount: 1,
            circuitBreakerDelay: .seconds(5 * 60)
        )
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await connector.closeLatestConnection()
        for _ in 0..<100 {
            if await pool.snapshot().retryingKeys.contains(target.key) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        await pool.recoverRuntimeConnections()
        let snapshot = await pool.snapshot()
        #expect(snapshot.failureCounts[target.key] == 1)
        #expect(snapshot.retryingKeys.contains(target.key))
        #expect(await connector.openCount == 1)
        await pool.shutdown()
    }

    @Test func failedLeaseValidationCanOpenTheCircuit() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(
            connector: connector,
            circuitBreakerFailureCount: 1,
            circuitBreakerDelay: .seconds(5 * 60)
        )
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        await connector.failLatestConnectionPing()

        #expect(await pool.lease(for: target) == nil)
        let snapshot = await pool.snapshot()
        #expect(snapshot.failureCounts[target.key] == 1)
        #expect(snapshot.retryingKeys.contains(target.key))
        #expect(await connector.openCount == 1)
        await pool.shutdown()
    }

    @Test func idleStandbyPausesAndTheNextUseReactivatesIt() async throws {
        let connector = FakeCloudSpeechConnector()
        let pool = CloudSpeechConnectionPool(
            connector: connector,
            idleTimeout: .milliseconds(40)
        )
        let target = CloudSpeechConnectionTarget.aliyun(
            apiKey: "test-key",
            endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!
        )

        await pool.reconcile(targets: [target])
        try await waitUntilReady(pool, key: target.key)
        try await waitUntilDormant(pool, key: target.key)

        var snapshot = await pool.snapshot()
        #expect(snapshot.readyKeys.isEmpty)
        #expect(snapshot.dormantKeys == [target.key])
        #expect(await connector.allConnectionsClosed)

        let leased = await pool.lease(for: target)
        #expect(leased == nil)
        try await waitUntilReady(pool, key: target.key)
        snapshot = await pool.snapshot()
        #expect(snapshot.dormantKeys.isEmpty)
        #expect(await connector.openCount == 2)

        await pool.shutdown()
    }

    private func waitUntilReady(
        _ pool: CloudSpeechConnectionPool,
        key: CloudSpeechConnectionKey
    ) async throws {
        for _ in 0..<100 {
            if await pool.snapshot().readyKeys.contains(key) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for standby connection")
    }

    private func waitUntilDormant(
        _ pool: CloudSpeechConnectionPool,
        key: CloudSpeechConnectionKey
    ) async throws {
        for _ in 0..<100 {
            if await pool.snapshot().dormantKeys.contains(key) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for standby connection to become dormant")
    }
}

private final class CloudSpeechPingCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Void, Error>] = []

    var completionCount: Int { lock.withLock { results.count } }
    var firstCompletionSucceeded: Bool {
        lock.withLock {
            guard let result = results.first else { return false }
            if case .success = result { return true }
            return false
        }
    }

    func record(_ result: Result<Void, Error>) {
        lock.withLock {
            results.append(result)
        }
    }
}

private actor FakeCloudSpeechConnector: CloudSpeechWebSocketConnecting {
    private var connections: [FakeCloudSpeechConnection] = []

    var openCount: Int { connections.count }
    var allConnectionsClosed: Bool { connections.allSatisfy(\.isClosed) }
    var totalSentMessages: Int { connections.reduce(0) { $0 + $1.sentMessageCount } }
    var totalPingCount: Int { connections.reduce(0) { $0 + $1.pingCount } }

    func connection(at index: Int) -> FakeCloudSpeechConnection? {
        guard connections.indices.contains(index) else { return nil }
        return connections[index]
    }

    func failLatestConnectionPing() {
        connections.last?.failPing()
    }

    func closeLatestConnection() {
        connections.last?.close()
    }

    func open(
        target _: CloudSpeechConnectionTarget,
        onClosed: (@Sendable (Error?) -> Void)?
    ) async throws -> any CloudSpeechWebSocketConnection {
        let connection = FakeCloudSpeechConnection(onClosed: onClosed)
        connections.append(connection)
        return connection
    }
}

private final class FakeCloudSpeechConnection: CloudSpeechWebSocketConnection, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "CloudSpeechPreconnectionTests.connection")
    private let onClosed: (@Sendable (Error?) -> Void)?
    private var storedIsClosed = false
    private var storedSentMessageCount = 0
    private var storedPingCount = 0
    private var shouldFailPing = false

    var isClosed: Bool { stateQueue.sync { storedIsClosed } }
    var sentMessageCount: Int { stateQueue.sync { storedSentMessageCount } }
    var pingCount: Int { stateQueue.sync { storedPingCount } }

    init(onClosed: (@Sendable (Error?) -> Void)?) {
        self.onClosed = onClosed
    }

    func send(_: URLSessionWebSocketTask.Message) async throws {
        stateQueue.sync {
            storedSentMessageCount += 1
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw StreamingTranscriptionError.notConnected
    }

    func ping(timeout _: Duration) async throws {
        let shouldFail = stateQueue.sync {
            storedPingCount += 1
            return shouldFailPing
        }
        if shouldFail {
            throw URLError(.networkConnectionLost)
        }
    }

    func failPing() {
        stateQueue.sync {
            shouldFailPing = true
        }
    }

    func close() {
        let shouldNotify = stateQueue.sync {
            guard !storedIsClosed else { return false }
            storedIsClosed = true
            return true
        }
        if shouldNotify {
            onClosed?(nil)
        }
    }
}
