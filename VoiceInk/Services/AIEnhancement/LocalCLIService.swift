import Foundation

enum LocalCLIExecutionMode: String, CaseIterable, Identifiable {
    case command
    case codexAppServer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .command: return String(localized: "Command")
        case .codexAppServer: return String(localized: "Codex App Server")
        }
    }
}

enum LocalCLITemplate: String, CaseIterable, Identifiable {
    case pi
    case claude
    case codex
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: return "Pi"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        }
    }

    var commandTemplate: String {
        switch self {
        case .pi:
            return "pi -ne -ns -p --no-tools --system-prompt \"$VOICEINK_SYSTEM_PROMPT\" \"$VOICEINK_USER_PROMPT\""
        case .claude:
            return "claude -p \"$VOICEINK_FULL_PROMPT\""
        case .codex:
            return
                "TMPFILE=$(mktemp) && codex exec --skip-git-repo-check --output-last-message \"$TMPFILE\" \"$VOICEINK_FULL_PROMPT\" > /dev/null 2>&1 && cat \"$TMPFILE\" && rm \"$TMPFILE\""
        case .copilot:
            return "copilot -p \"$VOICEINK_FULL_PROMPT\" -s --no-ask-user --available-tools=__none__ 2>/dev/null"
        }
    }
}

final class LocalCLIService {
    static let commandTemplateKey = "localCLICommandTemplate"
    static let selectedTemplateKey = "localCLISelectedTemplate"
    static let timeoutSecondsKey = "localCLITimeoutSeconds"
    static let executionModeKey = "localCLIExecutionMode"
    static let codexModelKey = "localCLICodexModel"
    static let codexReasoningEffortKey = "localCLICodexReasoningEffort"
    static let defaultTimeoutSeconds: Double = 45
    static let defaultCodexReasoningEffort = "low"

    private let codexAppServer = CodexAppServerService()

    var commandTemplate: String {
        didSet {
            UserDefaults.standard.set(commandTemplate, forKey: Self.commandTemplateKey)
        }
    }

    var selectedTemplate: LocalCLITemplate {
        didSet {
            UserDefaults.standard.set(selectedTemplate.rawValue, forKey: Self.selectedTemplateKey)
        }
    }

    var timeoutSeconds: Double {
        didSet {
            let clamped = max(5, timeoutSeconds)
            if clamped != timeoutSeconds {
                timeoutSeconds = clamped
                return
            }
            UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutSecondsKey)
        }
    }

    var executionMode: LocalCLIExecutionMode {
        didSet {
            UserDefaults.standard.set(executionMode.rawValue, forKey: Self.executionModeKey)
            if executionMode != .codexAppServer {
                codexAppServer.shutdown()
            }
        }
    }

    var codexModel: String {
        didSet {
            UserDefaults.standard.set(codexModel, forKey: Self.codexModelKey)
        }
    }

    var codexReasoningEffort: String {
        didSet {
            UserDefaults.standard.set(codexReasoningEffort, forKey: Self.codexReasoningEffortKey)
        }
    }

    var isConfigured: Bool {
        switch executionMode {
        case .command:
            return !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .codexAppServer:
            return true
        }
    }

    init() {
        let savedTemplateRaw = UserDefaults.standard.string(forKey: Self.selectedTemplateKey) ?? ""
        selectedTemplate = LocalCLITemplate(rawValue: savedTemplateRaw) ?? .pi

        commandTemplate = UserDefaults.standard.string(forKey: Self.commandTemplateKey) ?? ""

        let savedTimeout = UserDefaults.standard.double(forKey: Self.timeoutSecondsKey)
        timeoutSeconds = savedTimeout > 0 ? savedTimeout : Self.defaultTimeoutSeconds

        codexModel = UserDefaults.standard.string(forKey: Self.codexModelKey) ?? ""
        codexReasoningEffort =
            UserDefaults.standard.string(forKey: Self.codexReasoningEffortKey)
            ?? Self.defaultCodexReasoningEffort

        let persistedDefaults = Bundle.main.bundleIdentifier.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
        if let savedMode = persistedDefaults?[Self.executionModeKey] as? String,
            let mode = LocalCLIExecutionMode(rawValue: savedMode)
        {
            executionMode = mode
        } else if selectedTemplate == .codex && commandTemplate == LocalCLITemplate.codex.commandTemplate {
            // Migrate only the untouched built-in Codex template. Custom commands remain custom.
            executionMode = .codexAppServer
            UserDefaults.standard.set(executionMode.rawValue, forKey: Self.executionModeKey)
        } else {
            executionMode = .command
        }
    }

    func loadTemplate(_ template: LocalCLITemplate) {
        selectedTemplate = template
        commandTemplate = template.commandTemplate
        executionMode = template == .codex ? .codexAppServer : .command
    }

    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        selectedTemplate = LocalCLITemplate(rawValue: defaults.string(forKey: Self.selectedTemplateKey) ?? "") ?? .pi
        commandTemplate = defaults.string(forKey: Self.commandTemplateKey) ?? ""
        let savedTimeout = defaults.double(forKey: Self.timeoutSecondsKey)
        timeoutSeconds = savedTimeout > 0 ? savedTimeout : Self.defaultTimeoutSeconds
        codexModel = defaults.string(forKey: Self.codexModelKey) ?? ""
        codexReasoningEffort = defaults.string(forKey: Self.codexReasoningEffortKey) ?? Self.defaultCodexReasoningEffort
        executionMode =
            LocalCLIExecutionMode(rawValue: defaults.string(forKey: Self.executionModeKey) ?? "") ?? .command
    }

    func enhance(systemPrompt: String, userPrompt: String) async throws -> String {
        guard isConfigured else {
            throw LocalCLIError.commandNotConfigured
        }

        if executionMode == .codexAppServer {
            let models = try await availableCodexModels()
            guard let model = selectedCodexModel(from: models) else {
                throw LocalCLIError.noCodexModels
            }
            let effort = CodexAppServerProtocol.resolvedEffort(codexReasoningEffort, for: model)
            return try await codexAppServer.enhance(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model.model,
                effort: effort,
                timeout: timeoutSeconds
            )
        }

        let fullPrompt = Self.makeFullPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        return try await executeCommand(
            commandTemplate: commandTemplate,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeout: timeoutSeconds
        )
    }

    func availableCodexModels() async throws -> [CodexModelOption] {
        try await codexAppServer.listModels()
    }

    @discardableResult
    func selectedCodexModel(from models: [CodexModelOption]) -> CodexModelOption? {
        var didChangeSelection = false
        if let selected = models.first(where: { $0.id == codexModel || $0.model == codexModel }) {
            let resolvedEffort = CodexAppServerProtocol.resolvedEffort(codexReasoningEffort, for: selected)
            if resolvedEffort != codexReasoningEffort {
                codexReasoningEffort = resolvedEffort
                didChangeSelection = true
            }
            if didChangeSelection {
                notifyConfigurationChanged()
            }
            return selected
        }

        guard let recommended = CodexAppServerProtocol.recommendedModel(in: models) else { return nil }
        codexModel = recommended.model
        codexReasoningEffort = CodexAppServerProtocol.resolvedEffort(Self.defaultCodexReasoningEffort, for: recommended)
        notifyConfigurationChanged()
        return recommended
    }

    private func notifyConfigurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    static func makeFullPrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        # System Message
        <SYSTEM_MESSAGE>
        \(systemPrompt)
        </SYSTEM_MESSAGE>

        # User Message Payload
        <USER_MESSAGE_PAYLOAD>
        \(userPrompt)
        </USER_MESSAGE_PAYLOAD>
        """
    }

    private func executeCommand(
        commandTemplate: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeout: Double
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", commandTemplate]

                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ShellCommandEnvironment.preferredPATH(fallback: environment["PATH"])
                environment["VOICEINK_SYSTEM_PROMPT"] = systemPrompt
                environment["VOICEINK_USER_PROMPT"] = userPrompt
                environment["VOICEINK_FULL_PROMPT"] = fullPrompt
                process.environment = environment

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: LocalCLIError.executionFailed(error.localizedDescription))
                    return
                }

                if let inputData = fullPrompt.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(inputData)
                }
                try? inputPipe.fileHandleForWriting.close()

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + timeout)
                if waitResult == .timedOut {
                    if process.isRunning {
                        process.terminate()
                        _ = semaphore.wait(timeout: .now() + 2)
                    }
                    continuation.resume(throwing: LocalCLIError.timeout(seconds: timeout))
                    return
                }

                let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = Self.cleanOutput(String(data: stdoutData, encoding: .utf8) ?? "")
                let stderr = Self.cleanOutput(String(data: stderrData, encoding: .utf8) ?? "")

                if process.terminationStatus != 0 {
                    let looksLikeCommandNotFound =
                        process.terminationStatus == 127 || stderr.lowercased().contains("command not found")
                    if looksLikeCommandNotFound {
                        continuation.resume(
                            throwing: LocalCLIError.commandNotFound(stderr.isEmpty ? commandTemplate : stderr))
                    } else {
                        continuation.resume(
                            throwing: LocalCLIError.nonZeroExit(status: Int(process.terminationStatus), stderr: stderr))
                    }
                    return
                }

                guard !stdout.isEmpty else {
                    continuation.resume(throwing: LocalCLIError.emptyOutput)
                    return
                }

                continuation.resume(returning: stdout)
            }
        }
    }

    private static func cleanOutput(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalCLIError: Error, LocalizedError {
    case commandNotConfigured
    case noCodexModels
    case commandNotFound(String)
    case timeout(seconds: Double)
    case nonZeroExit(status: Int, stderr: String)
    case emptyOutput
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandNotConfigured:
            return String(localized: "Local CLI command is not configured. Load a template or enter a command first.")
        case .noCodexModels:
            return String(localized: "Codex did not return any available models. Check your Codex sign-in and try again.")
        case .commandNotFound(let details):
            return String(
                format: String(
                    localized:
                        "Local CLI command was not found. Use an absolute path or fix your shell PATH. Details: %@"),
                details)
        case .timeout(let seconds):
            return String(format: String(localized: "Local CLI command timed out after %lld seconds."), Int64(seconds))
        case .nonZeroExit(let status, let stderr):
            if stderr.isEmpty {
                return String(format: String(localized: "Local CLI command failed with exit code %lld."), Int64(status))
            }
            return String(
                format: String(localized: "Local CLI command failed with exit code %lld: %@"), Int64(status), stderr)
        case .emptyOutput:
            return String(localized: "Local CLI command returned empty output.")
        case .executionFailed(let message):
            return String(format: String(localized: "Failed to execute Local CLI command: %@"), message)
        }
    }
}
