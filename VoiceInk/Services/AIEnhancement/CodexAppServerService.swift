import Darwin
import Foundation

struct CodexModelOption: Identifiable, Equatable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [String]

    var title: String {
        displayName.isEmpty ? model : displayName
    }
}

enum CodexAppServerProtocol {
    static func parseModelListResponse(_ data: Data) throws -> [CodexModelOption] {
        let root = try object(from: data)
        let result = try resultObject(from: root)
        guard let rawModels = result["data"] as? [[String: Any]] else {
            throw CodexAppServerError.invalidResponse("model/list did not return a model catalog")
        }

        return rawModels.compactMap { rawModel in
            guard let id = rawModel["id"] as? String,
                let model = rawModel["model"] as? String,
                (rawModel["hidden"] as? Bool) != true
            else {
                return nil
            }

            let efforts = (rawModel["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap {
                $0["reasoningEffort"] as? String
            }
            return CodexModelOption(
                id: id,
                model: model,
                displayName: rawModel["displayName"] as? String ?? model,
                description: rawModel["description"] as? String ?? "",
                isDefault: rawModel["isDefault"] as? Bool ?? false,
                defaultReasoningEffort: rawModel["defaultReasoningEffort"] as? String ?? efforts.first
                    ?? "low",
                supportedReasoningEfforts: efforts
            )
        }
    }

    static func recommendedModel(in models: [CodexModelOption]) -> CodexModelOption? {
        let preferredIDs = ["gpt-5.6-luna", "gpt-5.4-mini", "gpt-5.3-codex-spark"]
        for id in preferredIDs {
            if let model = models.first(where: { $0.id == id || $0.model == id }) {
                return model
            }
        }
        if let efficient = models.first(where: {
            let value = "\($0.id) \($0.model) \($0.displayName)".lowercased()
            return value.contains("luna") || value.contains("mini") || value.contains("spark")
        }) {
            return efficient
        }
        return models.first(where: \CodexModelOption.isDefault) ?? models.first
    }

    static func resolvedEffort(_ requested: String, for model: CodexModelOption) -> String {
        if model.supportedReasoningEfforts.contains(requested) {
            return requested
        }
        if model.supportedReasoningEfforts.contains("low") {
            return "low"
        }
        if model.supportedReasoningEfforts.contains(model.defaultReasoningEffort) {
            return model.defaultReasoningEffort
        }
        return model.supportedReasoningEfforts.first ?? model.defaultReasoningEffort
    }

    static func resultObject(from root: [String: Any]) throws -> [String: Any] {
        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown App Server error"
            throw CodexAppServerError.server(message)
        }
        guard let result = root["result"] as? [String: Any] else {
            throw CodexAppServerError.invalidResponse("App Server response did not contain a result")
        }
        return result
    }

    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerError.invalidResponse("App Server returned invalid JSON")
        }
        return object
    }
}

/// Keeps one Codex App Server process alive for the lifetime of the service. Requests are serialized,
/// but every enhancement uses a fresh ephemeral thread so text from separate dictations never shares context.
final class CodexAppServerService {
    private let workerQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.codex-app-server")
    private let readerQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.codex-app-server-reader",
        qos: .userInitiated
    )
    private let messageCondition = NSCondition()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var responses: [Int: Data] = [:]
    private var notifications: [Data] = []
    private var processFailure: String?
    private var nextRequestID = 1
    private var initialized = false
    private var stderrTail = Data()
    private(set) var processLaunchCount = 0

    deinit {
        shutdown()
    }

    func listModels() async throws -> [CodexModelOption] {
        try await perform {
            try self.ensureInitialized(timeout: 8)
            let response = try self.request(
                method: "model/list",
                params: ["includeHidden": false, "limit": 100],
                timeout: 8
            )
            return try CodexAppServerProtocol.parseModelListResponse(response)
        }
    }

    func enhance(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        effort: String,
        timeout: TimeInterval
    ) async throws -> String {
        try await perform {
            try self.ensureInitialized(timeout: min(8, timeout))
            self.discardNotifications()

            let threadResponse: Data
            do {
                threadResponse = try self.request(
                    method: "thread/start",
                    params: [
                        "model": model,
                        "cwd": NSTemporaryDirectory(),
                        "approvalPolicy": "never",
                        "sandbox": "read-only",
                        "ephemeral": true,
                        "dynamicTools": [],
                        "developerInstructions": systemPrompt,
                    ],
                    timeout: min(10, timeout)
                )
            } catch CodexAppServerError.timeout {
                // The server may have received the request even when its reply was lost. Stop it so an
                // untracked turn cannot continue consuming quota in the background.
                self.resetProcess()
                throw CodexAppServerError.timeout(seconds: timeout)
            }
            let threadResult = try CodexAppServerProtocol.resultObject(
                from: CodexAppServerProtocol.object(from: threadResponse))
            guard let thread = threadResult["thread"] as? [String: Any],
                let threadID = thread["id"] as? String
            else {
                throw CodexAppServerError.invalidResponse("thread/start did not return a thread ID")
            }

            let turnResponse: Data
            do {
                turnResponse = try self.request(
                    method: "turn/start",
                    params: [
                        "threadId": threadID,
                        "input": [["type": "text", "text": userPrompt]],
                        "model": model,
                        "effort": effort,
                    ],
                    timeout: min(10, timeout)
                )
            } catch CodexAppServerError.timeout {
                self.resetProcess()
                throw CodexAppServerError.timeout(seconds: timeout)
            }
            let turnResult = try CodexAppServerProtocol.resultObject(
                from: CodexAppServerProtocol.object(from: turnResponse))
            guard let turn = turnResult["turn"] as? [String: Any],
                let turnID = turn["id"] as? String
            else {
                throw CodexAppServerError.invalidResponse("turn/start did not return a turn ID")
            }

            do {
                let completion = try self.waitForTurnCompletion(
                    threadID: threadID,
                    turnID: turnID,
                    timeout: timeout
                )
                return try self.extractFinalText(from: completion)
            } catch CodexAppServerError.timeout {
                do {
                    _ = try self.request(
                        method: "turn/interrupt",
                        params: ["threadId": threadID, "turnId": turnID],
                        timeout: 2
                    )
                } catch {
                    self.resetProcess()
                }
                throw CodexAppServerError.timeout(seconds: timeout)
            }
        }
    }

    func shutdown() {
        messageCondition.lock()
        let runningProcess = process
        process = nil
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
        initialized = false
        processFailure = "Codex App Server stopped"
        messageCondition.broadcast()
        messageCondition.unlock()

        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if runningProcess.isRunning {
                _ = kill(runningProcess.processIdentifier, SIGKILL)
            }
        }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workerQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ensureInitialized(timeout: TimeInterval) throws {
        if initialized, process?.isRunning == true {
            return
        }

        resetProcess()
        try startProcess()
        let response = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "voiceink",
                    "title": "VoiceInk",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "0",
                ],
                "capabilities": ["experimentalApi": true],
            ],
            timeout: timeout
        )
        _ = try CodexAppServerProtocol.resultObject(from: CodexAppServerProtocol.object(from: response))
        try sendNotification(method: "initialized", params: [:])
        initialized = true
    }

    private func startProcess() throws {
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Polishing never uses tools. Clearing configured MCP servers avoids paying their startup cost on the first turn.
        newProcess.arguments = ["codex", "app-server", "-c", "mcp_servers={}"]
        newProcess.environment = ShellCommandEnvironment.commandEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        newProcess.standardInput = inputPipe
        newProcess.standardOutput = outputPipe
        newProcess.standardError = errorPipe

        messageCondition.lock()
        processFailure = nil
        responses.removeAll()
        notifications.removeAll()
        stderrTail.removeAll(keepingCapacity: true)
        messageCondition.unlock()

        newProcess.terminationHandler = { [weak self, weak newProcess] _ in
            guard let self, let newProcess else { return }
            self.messageCondition.lock()
            guard self.process === newProcess else {
                self.messageCondition.unlock()
                return
            }
            let details = self.stderrDescription()
            self.processFailure =
                details.isEmpty
                ? "Codex App Server exited with status \(newProcess.terminationStatus)"
                : details
            self.initialized = false
            self.messageCondition.broadcast()
            self.messageCondition.unlock()
        }

        do {
            try newProcess.run()
        } catch {
            throw CodexAppServerError.unavailable(error.localizedDescription)
        }

        processLaunchCount += 1
        process = newProcess
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        startReading(outputPipe.fileHandleForReading, for: newProcess, isStandardError: false)
        startReading(errorPipe.fileHandleForReading, for: newProcess, isStandardError: true)
    }

    private func startReading(_ handle: FileHandle, for sourceProcess: Process, isStandardError: Bool)
    {
        handle.readabilityHandler = { [weak self, weak sourceProcess] readableHandle in
            guard let self, let sourceProcess else { return }
            let data = readableHandle.availableData
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                return
            }
            self.readerQueue.async {
                if isStandardError {
                    self.appendStderr(data, from: sourceProcess)
                } else {
                    self.consumeOutput(data, from: sourceProcess)
                }
            }
        }
    }

    private func consumeOutput(_ data: Data, from sourceProcess: Process) {
        messageCondition.lock()
        guard process === sourceProcess else {
            messageCondition.unlock()
            return
        }
        outputBuffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        messageCondition.unlock()
        lines.forEach { receive($0, from: sourceProcess) }
    }

    private func receive(_ data: Data, from sourceProcess: Process) {
        guard let root = try? CodexAppServerProtocol.object(from: data) else { return }
        messageCondition.lock()
        guard process === sourceProcess else {
            messageCondition.unlock()
            return
        }
        if let id = (root["id"] as? NSNumber)?.intValue {
            responses[id] = data
        } else if root["method"] is String {
            notifications.append(data)
            if notifications.count > 2_000 {
                notifications.removeFirst(notifications.count - 2_000)
            }
        }
        messageCondition.broadcast()
        messageCondition.unlock()
    }

    private func appendStderr(_ data: Data, from sourceProcess: Process) {
        messageCondition.lock()
        guard process === sourceProcess else {
            messageCondition.unlock()
            return
        }
        stderrTail.append(data)
        if stderrTail.count > 16_384 {
            stderrTail.removeFirst(stderrTail.count - 16_384)
        }
        messageCondition.unlock()
    }

    private func request(method: String, params: [String: Any], timeout: TimeInterval) throws -> Data
    {
        let requestID = nextRequestID
        nextRequestID += 1
        try writeJSON(["method": method, "id": requestID, "params": params])

        let deadline = Date().addingTimeInterval(timeout)
        messageCondition.lock()
        defer { messageCondition.unlock() }
        while responses[requestID] == nil {
            if let processFailure {
                throw CodexAppServerError.unavailable(processFailure)
            }
            guard messageCondition.wait(until: deadline) else {
                throw CodexAppServerError.timeout(seconds: timeout)
            }
        }
        return responses.removeValue(forKey: requestID)!
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try writeJSON(["method": method, "params": params])
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let inputHandle, process?.isRunning == true else {
            throw CodexAppServerError.unavailable("Codex App Server is not running")
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try inputHandle.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.unavailable(error.localizedDescription)
        }
    }

    private func waitForTurnCompletion(threadID: String, turnID: String, timeout: TimeInterval) throws
        -> Data
    {
        let deadline = Date().addingTimeInterval(timeout)
        messageCondition.lock()
        defer { messageCondition.unlock() }

        while true {
            if let index = notifications.firstIndex(where: {
                guard let root = try? CodexAppServerProtocol.object(from: $0),
                    root["method"] as? String == "turn/completed",
                    let params = root["params"] as? [String: Any],
                    params["threadId"] as? String == threadID,
                    let turn = params["turn"] as? [String: Any]
                else { return false }
                return turn["id"] as? String == turnID
            }) {
                return notifications.remove(at: index)
            }
            if let processFailure {
                throw CodexAppServerError.unavailable(processFailure)
            }
            guard messageCondition.wait(until: deadline) else {
                throw CodexAppServerError.timeout(seconds: timeout)
            }
        }
    }

    private func extractFinalText(from completion: Data) throws -> String {
        let root = try CodexAppServerProtocol.object(from: completion)
        guard let params = root["params"] as? [String: Any],
            let turn = params["turn"] as? [String: Any]
        else {
            throw CodexAppServerError.invalidResponse("turn/completed did not include turn details")
        }

        if let error = turn["error"] as? [String: Any] {
            throw CodexAppServerError.server(error["message"] as? String ?? "Codex turn failed")
        }
        let status = turn["status"] as? String ?? ""
        guard status == "completed" else {
            throw CodexAppServerError.server("Codex turn ended with status \(status)")
        }

        let items = turn["items"] as? [[String: Any]] ?? []
        let messages = items.compactMap { item -> String? in
            guard item["type"] as? String == "agentMessage" else { return nil }
            return item["text"] as? String
        }
        guard let text = messages.last?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            throw CodexAppServerError.emptyOutput
        }
        return text
    }

    private func discardNotifications() {
        messageCondition.lock()
        notifications.removeAll(keepingCapacity: true)
        messageCondition.unlock()
    }

    private func resetProcess() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputHandle = nil
        initialized = false
        messageCondition.lock()
        responses.removeAll()
        notifications.removeAll()
        processFailure = nil
        outputBuffer.removeAll(keepingCapacity: true)
        messageCondition.unlock()
    }

    private func stderrDescription() -> String {
        String(data: stderrTail, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum CodexAppServerError: Error, LocalizedError {
    case unavailable(String)
    case timeout(seconds: TimeInterval)
    case server(String)
    case invalidResponse(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unavailable(let details):
            return String(format: String(localized: "Codex App Server is unavailable: %@"), details)
        case .timeout(let seconds):
            return String(
                format: String(localized: "Codex enhancement timed out after %lld seconds."), Int64(seconds)
            )
        case .server(let message):
            return String(format: String(localized: "Codex App Server failed: %@"), message)
        case .invalidResponse(let message):
            return String(
                format: String(localized: "Codex App Server returned an invalid response: %@"), message)
        case .emptyOutput:
            return String(localized: "Codex App Server returned empty output.")
        }
    }
}
