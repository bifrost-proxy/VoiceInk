import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
struct CloudSpeechPreconnectionTests {
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
        try await waitUntilReady(pool, key: target.key)
        #expect(await connector.openCount == 2)

        leased?.close()
        try await Task.sleep(for: .milliseconds(20))
        let snapshot = await pool.snapshot()
        #expect(snapshot.readyKeys == [target.key])

        await pool.shutdown()
        #expect(await connector.allConnectionsClosed)
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
                await pool.shutdown()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the replacement standby connection")
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

private actor FakeCloudSpeechConnector: CloudSpeechWebSocketConnecting {
    private var connections: [FakeCloudSpeechConnection] = []

    var openCount: Int { connections.count }
    var allConnectionsClosed: Bool { connections.allSatisfy(\.isClosed) }
    var totalSentMessages: Int { connections.reduce(0) { $0 + $1.sentMessageCount } }

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

    var isClosed: Bool { stateQueue.sync { storedIsClosed } }
    var sentMessageCount: Int { stateQueue.sync { storedSentMessageCount } }

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

    func ping() async throws {}

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
