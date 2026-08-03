import Foundation

struct QwenMLXStreamSnapshot: Sendable, Equatable {
    let text: String
    let stableText: String
    let language: String
    let chunksProcessed: Int
    let rewriteEvents: Int
}

actor QwenMLXRuntime {
    static let shared = QwenMLXRuntime()

    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var readBuffer = Data()
    private var requestID = 0
    private var loadedModelPath: String?
    private var backendDescription: String?

    func load(model: QwenMLXModel) throws -> String {
        let modelPath = QwenMLXPaths.modelDirectory(for: model).path
        if process?.isRunning == true, loadedModelPath == modelPath,
            let backendDescription
        {
            return backendDescription
        }

        stopImmediately()
        try launchProcess()
        let response = try request([
            "command": "load",
            "model_path": modelPath,
        ])
        let backend = response["backend"] as? String ?? "unknown"
        guard backend.localizedCaseInsensitiveContains("gpu") else {
            stopImmediately()
            throw QwenMLXRuntimeError.gpuUnavailable(backend)
        }
        loadedModelPath = modelPath
        backendDescription = backend
        return backend
    }

    func beginStreaming(
        language: String?,
        context: String?,
        chunkSizeSeconds: Double = 1.0,
        maxContextSeconds: Double = 30.0
    ) throws -> QwenMLXStreamSnapshot {
        let response = try request([
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

    func feedAudio(_ pcm16Data: Data) throws -> QwenMLXStreamSnapshot {
        let response = try request([
            "command": "audio",
            "pcm16_base64": pcm16Data.base64EncodedString(),
        ])
        return try Self.snapshot(from: response)
    }

    func finishStreaming() throws -> QwenMLXStreamSnapshot {
        let response = try request(["command": "finish"])
        return try Self.snapshot(from: response)
    }

    func cancelStreaming() {
        guard process?.isRunning == true else { return }
        _ = try? request(["command": "cancel"])
    }

    func transcribe(audioURL: URL, language: String?, context: String?) throws -> String {
        let response = try request([
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

    func stop() {
        if process?.isRunning == true {
            _ = try? request(["command": "shutdown"])
        }
        stopImmediately()
    }

    func stopIfLoaded(model: QwenMLXModel) {
        guard loadedModelPath == QwenMLXPaths.modelDirectory(for: model).path else { return }
        stop()
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
        readBuffer.removeAll(keepingCapacity: true)
    }

    private func request(_ payload: [String: Any]) throws -> [String: Any] {
        guard let process, process.isRunning, let standardInput, standardOutput != nil else {
            throw QwenMLXRuntimeError.notRunning
        }

        requestID += 1
        var message = payload
        message["id"] = requestID
        let encoded = try JSONSerialization.data(withJSONObject: message)
        standardInput.write(encoded)
        standardInput.write(Data([0x0A]))

        let line = try readLine()
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw QwenMLXRuntimeError.invalidResponse("Response is not a JSON object")
        }
        guard (response["id"] as? Int) == requestID else {
            throw QwenMLXRuntimeError.invalidResponse("Response ID does not match request")
        }
        guard response["ok"] as? Bool == true else {
            throw QwenMLXRuntimeError.engineError(response["error"] as? String ?? "Unknown MLX error")
        }
        return response
    }

    private func readLine() throws -> Data {
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newlineIndex]
                readBuffer.removeSubrange(...newlineIndex)
                return Data(line)
            }

            guard let standardOutput else { throw QwenMLXRuntimeError.notRunning }
            // `readData(ofLength:)` may wait for the full requested byte count
            // on a pipe. The bridge emits one short JSON object per request, so
            // consume whatever is currently available and split it ourselves.
            let chunk = standardOutput.availableData
            guard !chunk.isEmpty else {
                let status = process?.terminationStatus ?? -1
                stopImmediately()
                throw QwenMLXRuntimeError.processExited(status)
            }
            readBuffer.append(chunk)
        }
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

    private func stopImmediately() {
        try? standardInput?.close()
        try? standardOutput?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        standardInput = nil
        standardOutput = nil
        readBuffer.removeAll(keepingCapacity: false)
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
