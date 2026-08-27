import AppKit
import CryptoKit
import Foundation

struct QwenMLXDownloadStatus {
    let fractionCompleted: Double
    let message: String
}

enum QwenMLXPaths {
    static let runtimeVersion = "mlx-qwen3-asr-0.3.5-mlx-0.32.0-python-3.12"

    static var rootDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["VOICEINK_QWEN_MLX_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VoiceInk/QwenMLX", isDirectory: true)
    }

    static var runtimeDirectory: URL {
        rootDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    static var pythonURL: URL {
        runtimeDirectory.appendingPathComponent("bin/python3")
    }

    static var runtimeMarkerURL: URL {
        runtimeDirectory.appendingPathComponent(".voiceink-runtime-version")
    }

    static var uvURL: URL {
        rootDirectory.appendingPathComponent("Tools/uv")
    }

    static var modelsDirectory: URL {
        rootDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    static func modelDirectory(for model: QwenMLXModel) -> URL {
        modelsDirectory.appendingPathComponent(model.name, isDirectory: true)
    }

    static func modelMarkerURL(for model: QwenMLXModel) -> URL {
        modelDirectory(for: model).appendingPathComponent(".voiceink-model-revision")
    }
}

@MainActor
final class QwenMLXModelManager: ObservableObject {
    static let shared = QwenMLXModelManager()

    @Published private(set) var downloadStatuses: [String: QwenMLXDownloadStatus] = [:]
    @Published private(set) var errors: [String: String] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private var activeDownloads: Set<String> = []

    private static let uvArchiveURL = URL(
        string: "https://github.com/astral-sh/uv/releases/download/0.12.1/uv-aarch64-apple-darwin.tar.gz"
    )!
    private static let uvArchiveSHA256 = "77d2906988e8074fd43f2f329ec452ebbf9b0c257ba1c66451c71de70a6baf42"

    func modelDirectory(for model: QwenMLXModel) -> URL {
        QwenMLXPaths.modelDirectory(for: model)
    }

    func isRuntimeReady() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: QwenMLXPaths.pythonURL.path),
            let marker = try? String(contentsOf: QwenMLXPaths.runtimeMarkerURL, encoding: .utf8)
        else {
            return false
        }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == QwenMLXPaths.runtimeVersion
    }

    func isDownloaded(_ model: QwenMLXModel) -> Bool {
        let directory = modelDirectory(for: model)
        let requiredFiles = [
            "config.json",
            "model.safetensors",
            "preprocessor_config.json",
            "tokenizer_config.json",
            "merges.txt",
            "vocab.json",
        ]
        guard requiredFiles.allSatisfy({
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }),
            let marker = try? String(contentsOf: QwenMLXPaths.modelMarkerURL(for: model), encoding: .utf8)
        else {
            return false
        }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == model.revision
    }

    func isReady(_ model: QwenMLXModel) -> Bool {
        SystemArchitecture.isAppleSilicon && isRuntimeReady() && isDownloaded(model)
    }

    func isDownloading(_ model: QwenMLXModel) -> Bool {
        activeDownloads.contains(model.name)
    }

    var isDownloadingAnyModel: Bool {
        !activeDownloads.isEmpty
    }

    func download(_ model: QwenMLXModel) async {
        guard SystemArchitecture.isAppleSilicon else {
            errors[model.name] = "Qwen MLX 仅支持 Apple Silicon Mac"
            return
        }
        guard !isReady(model), activeDownloads.isEmpty else { return }
        let operationID = ModelManagementActivity.shared.begin()
        defer { ModelManagementActivity.shared.end(operationID) }

        activeDownloads.insert(model.name)
        errors[model.name] = nil
        downloadStatuses[model.name] = .init(fractionCompleted: 0, message: "正在准备 MLX 运行时…")
        defer {
            activeDownloads.remove(model.name)
            downloadStatuses[model.name] = nil
            onModelsChanged?()
        }

        do {
            try FileManager.default.createDirectory(
                at: QwenMLXPaths.rootDirectory,
                withIntermediateDirectories: true
            )

            if !isRuntimeReady() {
                try await installRuntime(for: model)
            }

            if !isDownloaded(model) {
                downloadStatuses[model.name] = .init(
                    fractionCompleted: 0.56,
                    message: downloadMessage(for: model)
                )
                try await downloadModel(model)
            }

            guard isReady(model) else {
                throw QwenMLXManagerError.incompleteInstallation
            }
            downloadStatuses[model.name] = .init(fractionCompleted: 1, message: "安装完成")
        } catch {
            errors[model.name] = error.localizedDescription
        }
    }

    func delete(_ model: QwenMLXModel) {
        Task {
            let operationID = ModelManagementActivity.shared.begin()
            defer { ModelManagementActivity.shared.end(operationID) }
            await QwenMLXRuntime.shared.stopIfLoaded(model: model)
            do {
                let directory = modelDirectory(for: model)
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                errors[model.name] = nil
                onModelDeleted?(model.name)
                onModelsChanged?()
            } catch {
                errors[model.name] = error.localizedDescription
            }
        }
    }

    func showInFinder(_ model: QwenMLXModel) {
        NSWorkspace.shared.selectFile(modelDirectory(for: model).path, inFileViewerRootedAtPath: "")
    }

    private func installRuntime(for model: QwenMLXModel) async throws {
        downloadStatuses[model.name] = .init(fractionCompleted: 0.02, message: "正在下载隔离运行时…")

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInk-QwenMLX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let archiveURL = temporaryDirectory.appendingPathComponent("uv.tar.gz")
        let delegate = QwenMLXDownloadDelegate { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.downloadStatuses[model.name] = .init(
                    fractionCompleted: 0.02 + fraction * 0.10,
                    message: "正在下载隔离运行时…"
                )
            }
        }
        let downloadedURL = try await delegate.download(from: Self.uvArchiveURL)
        try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)

        guard try Self.sha256(of: archiveURL) == Self.uvArchiveSHA256 else {
            throw QwenMLXManagerError.runtimeChecksumMismatch
        }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try await Self.runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", extractedDirectory.path]
        )

        let extractedUV = extractedDirectory
            .appendingPathComponent("uv-aarch64-apple-darwin/uv")
        guard FileManager.default.fileExists(atPath: extractedUV.path) else {
            throw QwenMLXManagerError.incompleteInstallation
        }

        try FileManager.default.createDirectory(
            at: QwenMLXPaths.uvURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: QwenMLXPaths.uvURL.path) {
            try FileManager.default.removeItem(at: QwenMLXPaths.uvURL)
        }
        try FileManager.default.copyItem(at: extractedUV, to: QwenMLXPaths.uvURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: QwenMLXPaths.uvURL.path)

        if FileManager.default.fileExists(atPath: QwenMLXPaths.runtimeDirectory.path) {
            try FileManager.default.removeItem(at: QwenMLXPaths.runtimeDirectory)
        }

        downloadStatuses[model.name] = .init(fractionCompleted: 0.15, message: "正在安装 Python 3.12…")
        let environment = Self.runtimeInstallEnvironment
        try await Self.runProcess(
            executable: QwenMLXPaths.uvURL,
            arguments: [
                "venv", "--python", "3.12", "--managed-python", "--relocatable",
                "--no-project", "--clear", QwenMLXPaths.runtimeDirectory.path,
            ],
            environment: environment
        )

        downloadStatuses[model.name] = .init(fractionCompleted: 0.34, message: "正在安装 MLX 流式引擎…")
        try await Self.runProcess(
            executable: QwenMLXPaths.uvURL,
            arguments: [
                "pip", "install", "--python", QwenMLXPaths.pythonURL.path,
                "mlx==0.32.0", "mlx-qwen3-asr==0.3.5", "numpy==2.5.1",
                "regex==2026.7.19", "huggingface-hub==1.26.0",
            ],
            environment: environment
        )

        try QwenMLXPaths.runtimeVersion.write(
            to: QwenMLXPaths.runtimeMarkerURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func downloadModel(_ model: QwenMLXModel) async throws {
        let directory = modelDirectory(for: model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = """
        import sys
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
        """
        var environment = Self.runtimeInstallEnvironment
        environment["HF_HOME"] = QwenMLXPaths.rootDirectory
            .appendingPathComponent("HuggingFaceCache", isDirectory: true).path
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"

        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let downloadedBytes = Self.directorySize(at: directory)
                let modelFraction = min(0.98, Double(downloadedBytes) / Double(model.expectedDownloadBytes))
                self?.downloadStatuses[model.name] = .init(
                    fractionCompleted: 0.56 + modelFraction * 0.43,
                    message: self?.downloadMessage(for: model) ?? "正在下载 Qwen3-ASR 模型…"
                )
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await Self.runProcess(
                executable: QwenMLXPaths.pythonURL,
                arguments: ["-c", script, model.repositoryID, model.revision, directory.path],
                environment: environment
            )
            let weightsURL = directory.appendingPathComponent("model.safetensors")
            guard try Self.sha256(of: weightsURL) == model.modelSHA256 else {
                throw QwenMLXManagerError.modelChecksumMismatch
            }
            try model.revision.write(
                to: QwenMLXPaths.modelMarkerURL(for: model),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func downloadMessage(for model: QwenMLXModel) -> String {
        "正在下载 Qwen3-ASR MLX \(model.precision.rawValue) 模型（\(model.size.replacingOccurrences(of: " + 运行时", with: ""))）…"
    }

    private static var runtimeInstallEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["UV_PYTHON_INSTALL_DIR"] = QwenMLXPaths.rootDirectory
            .appendingPathComponent("Python", isDirectory: true).path
        environment["UV_CACHE_DIR"] = QwenMLXPaths.rootDirectory
            .appendingPathComponent("UVCache", isDirectory: true).path
        environment["UV_NO_PROGRESS"] = "1"
        environment["UV_NO_CONFIG"] = "1"
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        return environment
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1_048_576)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    nonisolated private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        async let outputData = standardOutput.fileHandleForReading.readToEnd()
        async let errorData = standardError.fileHandleForReading.readToEnd()
        try await runAndWait(process)
        let output = try await outputData ?? Data()
        let error = try await errorData ?? Data()

        guard process.terminationStatus == 0 else {
            let detail = String(data: error.isEmpty ? output : error, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw QwenMLXManagerError.processFailed(
                executable.lastPathComponent,
                process.terminationStatus,
                detail ?? ""
            )
        }
    }

    nonisolated private static func runAndWait(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum QwenMLXManagerError: LocalizedError {
    case runtimeChecksumMismatch
    case modelChecksumMismatch
    case incompleteInstallation
    case processFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .runtimeChecksumMismatch:
            return "MLX 运行时校验失败，请重新下载"
        case .modelChecksumMismatch:
            return "Qwen MLX 模型校验失败，请重新下载"
        case .incompleteInstallation:
            return "Qwen MLX 运行时或模型文件不完整"
        case .processFailed(let command, let status, let detail):
            let suffix = detail.isEmpty ? "" : "：\(detail)"
            return "\(command) 执行失败（\(status)）\(suffix)"
        }
    }
}

private final class QwenMLXDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let retained = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: retained)
            continuation?.resume(returning: retained)
            continuation = nil
            session.finishTasksAndInvalidate()
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, continuation != nil else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.invalidateAndCancel()
    }
}
