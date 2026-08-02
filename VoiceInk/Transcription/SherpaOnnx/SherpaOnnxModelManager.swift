import AppKit
import CryptoKit
import Foundation

struct SherpaOnnxDownloadStatus {
    let fractionCompleted: Double
    let message: String
}

@MainActor
final class SherpaOnnxModelManager: ObservableObject {
    static let shared = SherpaOnnxModelManager()

    @Published private(set) var downloadStatuses: [String: SherpaOnnxDownloadStatus] = [:]
    @Published private(set) var errors: [String: String] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private var activeDownloads: Set<String> = []

    func modelDirectory(for model: SherpaOnnxModel) -> URL {
        Self.modelsRootDirectory.appendingPathComponent(model.extractedDirectoryName, isDirectory: true)
    }

    func isDownloaded(_ model: SherpaOnnxModel) -> Bool {
        let directory = modelDirectory(for: model)
        switch model.kind {
        case .qwen3Asr:
            return ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer"]
                .allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        case .zipformerCtc:
            return ["model.int8.onnx", "tokens.txt"]
                .allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
    }

    func isDownloading(_ model: SherpaOnnxModel) -> Bool {
        activeDownloads.contains(model.name)
    }

    func download(_ model: SherpaOnnxModel) async {
        guard !isDownloaded(model), !isDownloading(model) else { return }
        activeDownloads.insert(model.name)
        errors[model.name] = nil
        downloadStatuses[model.name] = .init(fractionCompleted: 0, message: "正在下载模型…")
        defer {
            activeDownloads.remove(model.name)
            downloadStatuses[model.name] = nil
            onModelsChanged?()
        }

        do {
            try FileManager.default.createDirectory(at: Self.modelsRootDirectory, withIntermediateDirectories: true)
            let archiveURL = Self.modelsRootDirectory.appendingPathComponent("\(model.name).tar.bz2")
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }

            let delegate = SherpaDownloadDelegate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.downloadStatuses[model.name] = .init(
                        fractionCompleted: fraction * 0.92,
                        message: "正在下载模型…"
                    )
                }
            }
            let temporaryURL = try await delegate.download(from: model.archiveURL)
            try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)

            downloadStatuses[model.name] = .init(fractionCompleted: 0.94, message: "正在校验模型…")
            let digest = try Self.sha256(of: archiveURL)
            guard digest == model.archiveSHA256.lowercased() else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "模型校验失败，请重新下载"
                ])
            }

            downloadStatuses[model.name] = .init(fractionCompleted: 0.97, message: "正在解压模型…")
            try await Self.extract(archiveURL: archiveURL, expectedDirectoryName: model.extractedDirectoryName)
            try? FileManager.default.removeItem(at: archiveURL)
            guard isDownloaded(model) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "解压后的模型文件不完整"
                ])
            }
        } catch {
            errors[model.name] = error.localizedDescription
        }
    }

    func delete(_ model: SherpaOnnxModel) {
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

    func showInFinder(_ model: SherpaOnnxModel) {
        NSWorkspace.shared.selectFile(modelDirectory(for: model).path, inFileViewerRootedAtPath: "")
    }

    private static var modelsRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VoiceInk/SherpaOnnxModels", isDirectory: true)
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

    nonisolated private static func extract(archiveURL: URL, expectedDirectoryName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archiveURL.path, "-C", archiveURL.deletingLastPathComponent().path]
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "模型解压失败（tar \(process.terminationStatus)）"
                    ]))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let expected = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(expectedDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: expected.path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

private final class SherpaDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
