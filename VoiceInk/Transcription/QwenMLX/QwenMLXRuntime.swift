import Darwin
import Foundation

final class QwenMLXBlockingResponseReader: @unchecked Sendable {
    private let standardOutput: FileHandle
    private let process: Process
    private let onReadStart: (@Sendable () -> Void)?
    private var readBuffer = Data()

    init(
        standardOutput: FileHandle,
        process: Process,
        onReadStart: (@Sendable () -> Void)? = nil
    ) {
        self.standardOutput = standardOutput
        self.process = process
        self.onReadStart = onReadStart
    }

    func readLine() throws -> Data {
        onReadStart?()
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newlineIndex]
                readBuffer.removeSubrange(...newlineIndex)
                return Data(line)
            }

            // `readData(ofLength:)` may wait for the full requested byte count
            // on a pipe. The bridge emits one short JSON object per request, so
            // consume whatever is currently available and split it ourselves.
            let chunk = standardOutput.availableData
            guard !chunk.isEmpty else {
                let status = process.isRunning ? -1 : process.terminationStatus
                throw QwenMLXRuntimeError.processExited(status)
            }
            readBuffer.append(chunk)
        }
    }
}

final class QwenMLXBlockingRequestWriter: @unchecked Sendable {
    private let writeOperation: @Sendable (Data) -> Void
    private let onWriteStart: (@Sendable () -> Void)?

    init(standardInput: FileHandle, onWriteStart: (@Sendable () -> Void)? = nil) {
        writeOperation = { standardInput.write($0) }
        self.onWriteStart = onWriteStart
    }

    init(
        writeOperation: @escaping @Sendable (Data) -> Void,
        onWriteStart: (@Sendable () -> Void)? = nil
    ) {
        self.writeOperation = writeOperation
        self.onWriteStart = onWriteStart
    }

    func write(_ data: Data) {
        onWriteStart?()
        writeOperation(data)
    }
}

struct QwenMLXStreamSnapshot: Sendable, Equatable {
    let text: String
    let stableText: String
    let language: String
    let chunksProcessed: Int
    let rewriteEvents: Int
}

enum QwenMLXCancellationBridge {
    static func run<T>(
        operation: () async throws -> T,
        stopRuntime: @escaping @Sendable () async -> Void
    ) async rethrows -> T {
        let stopCoordinator = QwenMLXCancellationStopCoordinator(stopRuntime: stopRuntime)
        return try await withTaskCancellationHandler {
            do {
                let result = try await operation()
                await stopCoordinator.sealAndWaitForStopIfRequested()
                return result
            } catch {
                await stopCoordinator.sealAndWaitForStopIfRequested()
                throw error
            }
        } onCancel: {
            // The bridge may ignore Swift cancellation while blocked on stdout.
            // Start shutdown immediately, then keep admission until it finishes.
            stopCoordinator.requestStop()
        }
    }
}

final class QwenMLXCancellationStopCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let stopRuntime: @Sendable () async -> Void
    private var stopTask: Task<Void, Never>?
    private var isSealed = false

    init(stopRuntime: @escaping @Sendable () async -> Void) {
        self.stopRuntime = stopRuntime
    }

    func requestStop() {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed, stopTask == nil else { return }
        stopTask = Task { await stopRuntime() }
    }

    func sealAndWaitForStopIfRequested() async {
        await sealAndTakeStopTask()?.value
    }

    private func sealAndTakeStopTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        isSealed = true
        return stopTask
    }
}

/// Serializes bridge requests without occupying the runtime actor. Shutdown is
/// intentionally kept outside this queue so a wedged response can still be
/// interrupted by closing the bridge pipes.
final class QwenMLXRequestAdmissionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws {
        await withCheckedContinuation { continuation in
            let acquiredImmediately = lock.withLock { () -> Bool in
                if !isOccupied {
                    isOccupied = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquiredImmediately {
                continuation.resume()
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // A resumed waiter owns the admission slot. Hand it to the next
            // waiter before propagating cancellation.
            release()
            throw error
        }
    }

    func release() {
        let nextWaiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else {
                isOccupied = false
                return nil
            }
            // Keep the slot occupied while transferring ownership directly to
            // the oldest queued request.
            return waiters.removeFirst()
        }
        nextWaiter?.resume()
    }
}

actor QwenMLXRuntime {
    static let shared = QwenMLXRuntime()

    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var requestWriter: QwenMLXBlockingRequestWriter?
    private var responseReader: QwenMLXBlockingResponseReader?
    private var requestID = 0
    private var activeResponseRequestID: Int?
    private var loadedModelPath: String?
    private var backendDescription: String?
    private var isStopping = false
    private var shutdownTask: Task<Void, Never>?
    private let requestAdmission = QwenMLXRequestAdmissionQueue()

    static let shutdownGracePeriod: Duration = .milliseconds(500)
    static let shutdownPollInterval: Duration = .milliseconds(25)

    func load(model: QwenMLXModel) async throws -> String {
        try await requestAdmission.acquire()
        defer { requestAdmission.release() }
        // Install cancellation recovery only after admission so cancelling a
        // queued caller cannot stop another caller's active bridge request.
        return try await QwenMLXCancellationBridge.run {
            guard !isStopping else { throw QwenMLXRuntimeError.notRunning }
            let modelPath = QwenMLXPaths.modelDirectory(for: model).path
            if process?.isRunning == true, loadedModelPath == modelPath,
                let backendDescription
            {
                return backendDescription
            }

            await stop()
            try launchProcess()
            let response = try await requestWhileAdmitted([
                "command": "load",
                "model_path": modelPath,
            ])
            let backend = response["backend"] as? String ?? "unknown"
            guard backend.localizedCaseInsensitiveContains("gpu") else {
                await stop()
                throw QwenMLXRuntimeError.gpuUnavailable(backend)
            }
            loadedModelPath = modelPath
            backendDescription = backend
            return backend
        } stopRuntime: {
            await self.stop()
        }
    }

    func beginStreaming(
        language: String?,
        context: String?,
        chunkSizeSeconds: Double = 1.0,
        maxContextSeconds: Double = 30.0
    ) async throws -> QwenMLXStreamSnapshot {
        let response = try await performRequest([
            "command": "start",
            "language": language ?? "auto",
            "context": context ?? "",
            "chunk_size_sec": chunkSizeSeconds,
            "max_context_sec": maxContextSeconds,
            "finalization_mode": "accuracy",
            "endpointing_mode": "energy",
        ])
        return try Self.snapshot(from: response)
    }

    func feedAudio(_ pcm16Data: Data) async throws -> QwenMLXStreamSnapshot {
        let response = try await performRequest([
            "command": "audio",
            "pcm16_base64": pcm16Data.base64EncodedString(),
        ])
        return try Self.snapshot(from: response)
    }

    func finishStreaming() async throws -> QwenMLXStreamSnapshot {
        let response = try await performRequest(["command": "finish"])
        return try Self.snapshot(from: response)
    }

    func cancelStreaming(gracePeriod: Duration = shutdownGracePeriod) async {
        guard process?.isRunning == true else { return }
        // Reuse the bounded process shutdown. A separate cancel write could
        // itself fill behind a wedged stdin consumer and delay recovery.
        await stop(gracePeriod: gracePeriod)
    }

    func transcribe(audioURL: URL, language: String?, context: String?) async throws -> String {
        let response = try await performRequest([
            "command": "transcribe",
            "audio_path": audioURL.path,
            "language": language ?? "auto",
            "context": context ?? "",
        ])
        guard let text = response["text"] as? String else {
            throw QwenMLXRuntimeError.invalidResponse("Missing transcript text")
        }
        return text
    }

    func stop(gracePeriod: Duration = shutdownGracePeriod) async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        guard let process, process.isRunning else {
            clearRuntimeState()
            return
        }

        isStopping = true
        // Do not await the graceful write before starting the deadline: stdin
        // may be full when the bridge is wedged. Closing the pipe below releases
        // both this detached writer and any detached response reader.
        let gracefulWriteTask = Task {
            _ = try? await self.writeRequest(["command": "shutdown"])
        }

        let task = Task {
            let exitedGracefully = await Self.waitForExit(process, timeout: gracePeriod)
            if !exitedGracefully {
                // Closing the pipe releases any detached response reader before
                // escalating from SIGTERM to SIGKILL and confirming process exit.
                try? standardInput?.close()
                try? standardOutput?.close()
                _ = await Self.terminateAndWait(process, timeout: gracePeriod)
            }
            await gracefulWriteTask.value
            clearRuntimeState()
            isStopping = false
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    func stopIfLoaded(model: QwenMLXModel) async {
        guard loadedModelPath == QwenMLXPaths.modelDirectory(for: model).path else { return }
        await stop()
    }

    func releaseResourcesIfUnbound(boundModelNames: Set<String>) async -> String? {
        guard let loadedModelPath else { return nil }
        let loadedModelName = URL(fileURLWithPath: loadedModelPath).lastPathComponent
        guard !boundModelNames.contains(loadedModelName) else { return nil }
        await stop()
        return loadedModelName
    }

    private func launchProcess() throws {
        guard FileManager.default.isExecutableFile(atPath: QwenMLXPaths.pythonURL.path) else {
            throw QwenMLXRuntimeError.runtimeNotInstalled
        }
        guard let runnerURL = Self.runnerURL() else {
            throw QwenMLXRuntimeError.runnerMissing
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = QwenMLXPaths.pythonURL
        process.arguments = ["-u", runnerURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        requestWriter = QwenMLXBlockingRequestWriter(standardInput: inputPipe.fileHandleForWriting)
        responseReader = QwenMLXBlockingResponseReader(
            standardOutput: outputPipe.fileHandleForReading,
            process: process
        )
    }

    private func performRequest(_ payload: [String: Any]) async throws -> [String: Any] {
        try await requestAdmission.acquire()
        defer { requestAdmission.release() }
        // See load(model:): queued cancellation must not interrupt the owner.
        return try await QwenMLXCancellationBridge.run {
            try await requestWhileAdmitted(payload)
        } stopRuntime: {
            await self.stop()
        }
    }

    private func requestWhileAdmitted(_ payload: [String: Any]) async throws -> [String: Any] {
        guard !isStopping, let process, process.isRunning, let responseReader else {
            throw QwenMLXRuntimeError.notRunning
        }

        let sentRequestID = try await writeRequest(payload)
        activeResponseRequestID = sentRequestID
        defer {
            if activeResponseRequestID == sentRequestID {
                activeResponseRequestID = nil
            }
        }
        // The pipe read must not occupy this actor. If the bridge wedges, actor
        // reentrancy lets cancelStreaming()/stop() start their bounded shutdown
        // and close the pipe, which in turn releases this detached read.
        let line = try await Self.readResponseOffActor(responseReader)
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw QwenMLXRuntimeError.invalidResponse("Response is not a JSON object")
        }
        guard (response["id"] as? Int) == sentRequestID else {
            throw QwenMLXRuntimeError.invalidResponse("Response ID does not match request")
        }
        guard response["ok"] as? Bool == true else {
            throw QwenMLXRuntimeError.engineError(response["error"] as? String ?? "Unknown MLX error")
        }
        return response
    }

    static func readResponseOffActor(_ reader: QwenMLXBlockingResponseReader) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try reader.readLine()
        }.value
    }

    static func writeRequestOffActor(_ writer: QwenMLXBlockingRequestWriter, data: Data) async {
        await Task.detached(priority: .userInitiated) {
            writer.write(data)
        }.value
    }

    @discardableResult
    private func writeRequest(_ payload: [String: Any]) async throws -> Int {
        guard let process, process.isRunning, let requestWriter else {
            throw QwenMLXRuntimeError.notRunning
        }
        requestID += 1
        var message = payload
        message["id"] = requestID
        var encoded = try JSONSerialization.data(withJSONObject: message)
        encoded.append(0x0A)
        await Self.writeRequestOffActor(requestWriter, data: encoded)
        return requestID
    }

    static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: shutdownPollInterval)
        }
        return !process.isRunning
    }

    static func terminateAndWait(_ process: Process, timeout: Duration) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitForExit(process, timeout: timeout) {
            return true
        }

        guard process.isRunning else { return true }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        // SIGKILL cannot be handled by the bridge. Confirm its termination off
        // actor before allowing pressure cleanup or a replacement launch.
        await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
        }.value
        return !process.isRunning
    }

    private static func snapshot(from response: [String: Any]) throws -> QwenMLXStreamSnapshot {
        guard let text = response["text"] as? String,
            let stableText = response["stable_text"] as? String
        else {
            throw QwenMLXRuntimeError.invalidResponse("Missing streaming transcript fields")
        }
        let metrics = response["metrics"] as? [String: Any]
        return QwenMLXStreamSnapshot(
            text: text,
            stableText: stableText,
            language: response["language"] as? String ?? "unknown",
            chunksProcessed: metrics?["chunks_processed"] as? Int ?? 0,
            rewriteEvents: metrics?["rewrite_events"] as? Int ?? 0
        )
    }

    private static func runnerURL() -> URL? {
        Bundle.main.url(forResource: "qwen_mlx_runtime", withExtension: "py")
            ?? Bundle.main.url(
                forResource: "qwen_mlx_runtime",
                withExtension: "py",
                subdirectory: "Transcription/QwenMLX"
            )
    }

    private func clearRuntimeState() {
        try? standardInput?.close()
        try? standardOutput?.close()
        process = nil
        standardInput = nil
        standardOutput = nil
        requestWriter = nil
        responseReader = nil
        activeResponseRequestID = nil
        loadedModelPath = nil
        backendDescription = nil
    }
}

enum QwenMLXRuntimeError: LocalizedError {
    case runtimeNotInstalled
    case runnerMissing
    case notRunning
    case gpuUnavailable(String)
    case processExited(Int32)
    case invalidResponse(String)
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            return "Qwen MLX 隔离运行时尚未安装"
        case .runnerMissing:
            return "VoiceInk 缺少 Qwen MLX 运行脚本"
        case .notRunning:
            return "Qwen MLX 运行时未启动"
        case .gpuUnavailable(let backend):
            return "Qwen MLX 未能启用 Metal GPU（当前后端：\(backend)）"
        case .processExited(let status):
            return "Qwen MLX 运行时意外退出（\(status)）"
        case .invalidResponse(let detail):
            return "Qwen MLX 返回了无效响应：\(detail)"
        case .engineError(let detail):
            return "Qwen MLX 推理失败：\(detail)"
        }
    }
}
