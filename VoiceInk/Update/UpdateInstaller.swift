import CryptoKit
import Foundation

enum UpdatePreparationProgress: Equatable, Sendable {
    case downloading(Double?)
    case verifying
    case preparing
}

struct UpdateInstallationPlan: Sendable {
    let helperURL: URL
    let watchdogReadyURL: URL
    let arguments: [String]

    func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path] + arguments
        try process.run()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            if FileManager.default.fileExists(atPath: watchdogReadyURL.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: watchdogReadyURL.path) else {
            if process.isRunning {
                process.terminate()
            }
            throw UpdateInstaller.Failure.helperCreationFailed
        }
    }
}

enum UpdateInstaller {
    enum Failure: LocalizedError {
        case invalidDownload
        case checksumMismatch
        case archiveFailure(String)
        case missingApp
        case invalidBundle
        case versionMismatch(String)
        case invalidArchitecture
        case invalidSignature(String)
        case appNotWritable
        case helperCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidDownload:
                return String(localized: "The update could not be downloaded.")
            case .checksumMismatch:
                return String(localized: "The downloaded update failed its checksum verification.")
            case .archiveFailure(let detail):
                return String(localized: "The update archive could not be opened: \(detail)")
            case .missingApp:
                return String(localized: "The update archive does not contain VoiceInk.app.")
            case .invalidBundle:
                return String(localized: "The downloaded update is not a valid VoiceInk app.")
            case .versionMismatch(let version):
                return String(localized: "The downloaded app has an unexpected version: \(version)")
            case .invalidArchitecture:
                return String(localized: "The downloaded app does not match this Mac's CPU architecture.")
            case .invalidSignature(let detail):
                return String(localized: "The downloaded app failed code-signature verification: \(detail)")
            case .appNotWritable:
                return String(localized: "VoiceInk cannot update itself from its current location.")
            case .helperCreationFailed:
                return String(localized: "VoiceInk could not prepare the update installer.")
            }
        }
    }

    private struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static func markUpdateLaunchHealthyIfNeeded() {
        guard let marker = ProcessInfo.processInfo.environment["VOICEINK_UPDATE_HEALTH_MARKER"],
            !marker.isEmpty
        else {
            return
        }

        let markerURL = URL(fileURLWithPath: marker).standardizedFileURL
        let allowedRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInk/Updates", isDirectory: true)
            .standardizedFileURL
        guard markerURL.lastPathComponent == "launch-healthy",
            markerURL.path.hasPrefix(allowedRoot.path + "/")
        else {
            return
        }
        FileManager.default.createFile(atPath: markerURL.path, contents: Data("ready".utf8))
    }

    static func prepare(
        release: VoiceInkRelease,
        progress: @escaping @Sendable (UpdatePreparationProgress) -> Void
    ) async throws -> UpdateInstallationPlan {
        try await Task.detached(priority: .userInitiated) {
            try await prepareOffMain(release: release, progress: progress)
        }.value
    }

    private static func prepareOffMain(
        release: VoiceInkRelease,
        progress: @escaping @Sendable (UpdatePreparationProgress) -> Void
    ) async throws -> UpdateInstallationPlan {
        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        guard currentApp.pathExtension == "app",
            Bundle.main.bundleIdentifier == "com.prakashjoshipax.VoiceInk",
            FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path)
        else {
            throw Failure.appNotWritable
        }

        guard UpdateService.isTrustedReleaseDownloadURL(release.archiveURL),
            UpdateService.isTrustedReleaseDownloadURL(release.checksumURL)
        else {
            throw UpdateService.Failure.untrustedURL
        }

        let checksumData = try await downloadSmallFile(from: release.checksumURL)
        let expectedChecksum = try UpdateService.checksum(for: UpdateService.archiveName, in: checksumData)

        let root = try makeUpdateDirectory()
        var shouldRemoveRoot = true
        defer {
            if shouldRemoveRoot {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let archiveURL = root.appendingPathComponent(UpdateService.archiveName)
        let expandedRoot = root.appendingPathComponent("Expanded", isDirectory: true)

        var request = URLRequest(url: release.archiveURL)
        request.timeoutInterval = 180
        request.setValue("VoiceInk/\(UpdateService.currentVersion)", forHTTPHeaderField: "User-Agent")
        progress(.downloading(0))
        let (archiveData, response) = try await UpdateDownload.receive(request: request) { fraction in
            progress(.downloading(fraction))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.invalidDownload
        }

        progress(.verifying)
        let actualChecksum = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualChecksum == expectedChecksum else {
            throw Failure.checksumMismatch
        }
        try archiveData.write(to: archiveURL, options: [.atomic])

        progress(.preparing)
        try FileManager.default.createDirectory(
            at: expandedRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let expansion = try run(
            "/usr/bin/ditto",
            ["-x", "-k", archiveURL.path, expandedRoot.path]
        )
        guard expansion.status == 0 else {
            throw Failure.archiveFailure(text(expansion.stderr))
        }

        let stagedApp = expandedRoot.appendingPathComponent("VoiceInk.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stagedApp.path) else {
            throw Failure.missingApp
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path])
        try verify(stagedApp, expectedVersion: release.version)
        let plan = try makePlan(root: root, stagedApp: stagedApp, currentApp: currentApp, version: release.version)
        shouldRemoveRoot = false
        return plan
    }

    private static func downloadSmallFile(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("VoiceInk/\(UpdateService.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.invalidDownload
        }
        return data
    }

    private static func makeUpdateDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInk/Updates", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private static func verify(_ appURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
            bundle.bundleIdentifier == "com.prakashjoshipax.VoiceInk"
        else {
            throw Failure.invalidBundle
        }

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        guard version == expectedVersion else {
            throw Failure.versionMismatch(version)
        }

        let signature = try run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        )
        guard signature.status == 0 else {
            throw Failure.invalidSignature(text(signature.stderr))
        }

        guard let executable = bundle.executableURL else {
            throw Failure.invalidBundle
        }
        let architectures = try run("/usr/bin/lipo", ["-archs", executable.path])
        let values = Set(text(architectures.stdout).split(whereSeparator: \.isWhitespace).map(String.init))
        guard architectures.status == 0,
            isValidArchitectureSet(values)
        else {
            throw Failure.invalidArchitecture
        }
    }

    static func isValidArchitectureSet(
        _ architectures: Set<String>,
        expected: ReleaseArchitecture = UpdateService.releaseArchitecture
    ) -> Bool {
        architectures == [expected.rawValue]
    }

    private static func makePlan(
        root: URL,
        stagedApp: URL,
        currentApp: URL,
        version: String
    ) throws -> UpdateInstallationPlan {
        let helper = root.appendingPathComponent("install-update.zsh")
        let backup = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".VoiceInk-update-backup-\(UUID().uuidString).app")
        let marker = root.appendingPathComponent("launch-healthy")
        let watchdogReady = root.appendingPathComponent("watchdog-ready")
        let logDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/VoiceInk", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let log = logDirectory.appendingPathComponent("update.log")

        let script = installationHelperScript()

        do {
            try Data(script.utf8).write(to: helper, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            throw Failure.helperCreationFailed
        }

        return UpdateInstallationPlan(
            helperURL: helper,
            watchdogReadyURL: watchdogReady,
            arguments: [
                String(ProcessInfo.processInfo.processIdentifier),
                currentApp.path,
                stagedApp.path,
                backup.path,
                marker.path,
                root.path,
                log.path,
                version,
                watchdogReady.path,
            ]
        )
    }

    static func installationHelperScript(
        expectedArchitecture: ReleaseArchitecture = UpdateService.releaseArchitecture
    ) -> String {
        """
            #!/bin/zsh
            set -u
            old_pid="$1"
            current_app="$2"
            staged_app="$3"
            backup_app="$4"
            marker="$5"
            update_root="$6"
            log_file="$7"
            expected_version="$8"
            watchdog_ready="$9"
            expected_architecture="\(expectedArchitecture.rawValue)"
            exec >>"$log_file" 2>&1

            \(processExitWatchdogScript())

            restore_previous() {
              /bin/rm -rf "$current_app"
              if [[ -d "$backup_app" ]]; then
                /bin/mv "$backup_app" "$current_app"
                /usr/bin/open -n --env "VOICEINK_UPDATE_ROLLBACK=1" "$current_app"
              fi
              /bin/rm -rf "$update_root"
            }

            if ! /bin/mv "$current_app" "$backup_app"; then
              /usr/bin/open -n --env "VOICEINK_UPDATE_ROLLBACK=1" "$current_app"
              /bin/rm -rf "$update_root"
              exit 1
            fi
            if ! /usr/bin/ditto "$staged_app" "$current_app"; then
              restore_previous
              exit 1
            fi
            /usr/bin/xattr -dr com.apple.quarantine "$current_app" 2>/dev/null || true

            info_plist="$current_app/Contents/Info.plist"
            executable="$current_app/Contents/MacOS/VoiceInk"
            installed_bundle=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)
            installed_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist" 2>/dev/null || true)
            installed_archs=$(/usr/bin/lipo -archs "$executable" 2>/dev/null || true)
            if [[ "$installed_bundle" != "com.prakashjoshipax.VoiceInk" \
               || "$installed_version" != "$expected_version" \
               || "$installed_archs" != "$expected_architecture" ]] \
               || ! /usr/bin/codesign --verify --deep --strict "$current_app"; then
              restore_previous
              exit 1
            fi

            if ! /usr/bin/open -n --env "VOICEINK_UPDATE_HEALTH_MARKER=$marker" "$current_app"; then
              restore_previous
              exit 1
            fi

            for attempt in {1..100}; do
              if [[ -f "$marker" ]]; then
                /bin/rm -rf "$backup_app" "$update_root"
                exit 0
              fi
              /bin/sleep 0.2
            done

            if ! /usr/bin/pgrep -x VoiceInk >/dev/null; then
              restore_previous
            fi
            exit 1
            """
    }

    static func processExitWatchdogScript(
        gracefulExitAttempts: Int = 25,
        terminationExitAttempts: Int = 15,
        forcedExitAttempts: Int = 10
    ) -> String {
        let gracefulAttempts = max(gracefulExitAttempts, 1)
        let terminationAttempts = max(terminationExitAttempts, 1)
        let forcedAttempts = max(forcedExitAttempts, 1)

        return """
            if ! /usr/bin/osascript -l JavaScript - \
              "$old_pid" \
              "\(gracefulAttempts)" "\(terminationAttempts)" "\(forcedAttempts)" \
              "$watchdog_ready" <<'VOICEINK_WATCHDOG_JXA'
            ObjC.import('AppKit')

            function run(argv) {
              const oldPid = Number(argv[0])
              const gracefulAttempts = Number(argv[1])
              const terminationAttempts = Number(argv[2])
              const forcedAttempts = Number(argv[3])
              const readyPath = argv[4]
              const application = $.NSRunningApplication.runningApplicationWithProcessIdentifier(oldPid)

              function markReady() {
                const data = $.NSString.stringWithString('ready').dataUsingEncoding($.NSUTF8StringEncoding)
                const created = $.NSFileManager.defaultManager
                  .createFileAtPathContentsAttributes(readyPath, data, $())
                if (!Boolean(created)) {
                  throw new Error('Could not create the update watchdog readiness marker.')
                }
              }

              if (application.isNil()) {
                markReady()
                return 'VoiceInk exited before the update watchdog attached.'
              }

              const bundleIdentifier = application.bundleIdentifier
              if (bundleIdentifier.isNil()) {
                throw new Error('Could not verify the running VoiceInk application identity.')
              }
              if (ObjC.unwrap(bundleIdentifier) !== 'com.prakashjoshipax.VoiceInk') {
                markReady()
                return 'The original VoiceInk PID has already exited and been reused.'
              }

              // Keep this application object for the full watchdog lifetime. Unlike a PID,
              // it cannot be retargeted if the original process exits and its PID is reused.
              markReady()

              function waitForExit(maximumAttempts) {
                for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
                  if (Boolean(application.terminated)) {
                    return true
                  }
                  $.NSRunLoop.currentRunLoop.runUntilDate(
                    $.NSDate.dateWithTimeIntervalSinceNow(0.2)
                  )
                }
                return Boolean(application.terminated)
              }

              if (waitForExit(gracefulAttempts)) {
                return 'VoiceInk exited gracefully.'
              }

              console.log('VoiceInk did not exit after a graceful quit; requesting termination.')
              application.terminate
              if (waitForExit(terminationAttempts)) {
                return 'VoiceInk exited after the termination request.'
              }

              console.log('VoiceInk did not exit after the termination request; forcing termination.')
              if (!Boolean(application.forceTerminate)) {
                throw new Error('Could not force the original VoiceInk process to terminate.')
              }

              while (!waitForExit(forcedAttempts)) {
                console.log('Waiting for the force-terminated VoiceInk process to disappear.')
              }
              return 'VoiceInk exited after forced termination.'
            }
            VOICEINK_WATCHDOG_JXA
            then
              print -r -- "Could not safely stop the original VoiceInk process; aborting update."
              /bin/rm -rf "$update_root"
              exit 1
            fi
            """
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? String(localized: "Unknown update error")
    }
}

private final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double?) -> Void
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?

    private init(progress: @escaping @Sendable (Double?) -> Void) {
        self.progress = progress
    }

    static func receive(
        request: URLRequest,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let receiver = UpdateDownload(progress: progress)
        return try await receiver.start(request: request)
    }

    private func start(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        self.response = response
        progress(nil)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.data.append(data)
        let expected = response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
        guard expected > 0 else {
            progress(nil)
            return
        }
        progress(min(Double(self.data.count) / Double(expected), 1))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            continuation = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let response else {
            continuation?.resume(throwing: UpdateInstaller.Failure.invalidDownload)
            return
        }
        if response.expectedContentLength > 0 { progress(1) }
        continuation?.resume(returning: (data, response))
    }
}
