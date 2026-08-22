import Darwin
import Foundation
import Testing
@testable import VoiceInk

struct UpdaterTests {
    private static let artifactTestPathURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceInk/Updates/.artifact-test-app-path")

    @Test func semanticVersionsUseNumericOrdering() {
        #expect(UpdateService.isNewer("2.3.0", than: "2.2.9"))
        #expect(UpdateService.isNewer("3.0.0", than: "2.99.99"))
        #expect(!UpdateService.isNewer("2.2.8", than: "2.2.8"))
        #expect(!UpdateService.isNewer("2.2.7", than: "2.2.8"))
        #expect(!UpdateService.isNewer("2.3.0-beta.1", than: "2.2.8"))
    }

    @Test func atomFeedSelectsTheNewestStableRelease() throws {
        let feed = """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <id>tag:github.com,2008:Repository/123/v2.2.9</id>
                <link rel="alternate" href="https://github.com/bifrost-proxy/VoiceInk/releases/tag/v2.2.9"/>
              </entry>
              <entry>
                <id>tag:github.com,2008:Repository/123/v2.3.0</id>
                <link rel="alternate" href="https://github.com/bifrost-proxy/VoiceInk/releases/tag/v2.3.0"/>
              </entry>
              <entry>
                <id>tag:github.com,2008:Repository/123/v3.0.0-beta.1</id>
                <link rel="alternate" href="https://github.com/bifrost-proxy/VoiceInk/releases/tag/v3.0.0-beta.1"/>
              </entry>
            </feed>
            """

        let arm64Release = try UpdateService.decodeAtomFeed(Data(feed.utf8), architecture: .arm64)
        #expect(arm64Release.version == "2.3.0")
        #expect(
            arm64Release.archiveURL.absoluteString
                == "https://github.com/bifrost-proxy/VoiceInk/releases/download/v2.3.0/VoiceInk-arm64.zip"
        )
        #expect(
            arm64Release.checksumURL.absoluteString
                == "https://github.com/bifrost-proxy/VoiceInk/releases/download/v2.3.0/SHA256SUMS"
        )

        let x86_64Release = try UpdateService.decodeAtomFeed(Data(feed.utf8), architecture: .x86_64)
        #expect(
            x86_64Release.archiveURL.absoluteString
                == "https://github.com/bifrost-proxy/VoiceInk/releases/download/v2.3.0/VoiceInk-x86_64.zip"
        )
    }

    @Test func atomFeedRejectsReleaseLinksOutsideTheVoiceInkRepository() {
        let feed = """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <id>tag:github.com,2008:Repository/123/v99.0.0</id>
                <link rel="alternate" href="https://github.com/example/VoiceInk/releases/tag/v99.0.0"/>
              </entry>
            </feed>
            """

        #expect(throws: UpdateService.Failure.self) {
            _ = try UpdateService.decodeAtomFeed(Data(feed.utf8))
        }
    }

    @Test func checksumManifestRequiresTheExactCPUSpecificArchive() throws {
        let arm64 = String(repeating: "b", count: 64)
        let x86_64 = String(repeating: "c", count: 64)
        let manifest = """
            \(arm64)  VoiceInk-arm64.zip
            \(x86_64)  VoiceInk-x86_64.zip
            """

        #expect(try UpdateService.checksum(for: "VoiceInk-arm64.zip", in: Data(manifest.utf8)) == arm64)
        #expect(try UpdateService.checksum(for: "VoiceInk-x86_64.zip", in: Data(manifest.utf8)) == x86_64)
        #expect(throws: UpdateService.Failure.self) {
            _ = try UpdateService.checksum(for: "Missing.zip", in: Data(manifest.utf8))
        }
    }

    @Test func updaterUsesOnlyTheCurrentCPUArchitecture() {
        #expect(UpdateService.archiveName(for: .arm64) == "VoiceInk-arm64.zip")
        #expect(UpdateService.archiveName(for: .x86_64) == "VoiceInk-x86_64.zip")

        #if arch(arm64)
            #expect(UpdateService.archiveName == "VoiceInk-arm64.zip")
        #elseif arch(x86_64)
            #expect(UpdateService.archiveName == "VoiceInk-x86_64.zip")
        #endif

        #expect(UpdateInstaller.isValidArchitectureSet(["arm64"], expected: .arm64))
        #expect(UpdateInstaller.isValidArchitectureSet(["x86_64"], expected: .x86_64))
        #expect(!UpdateInstaller.isValidArchitectureSet(["arm64", "x86_64"], expected: .arm64))
        #expect(!UpdateInstaller.isValidArchitectureSet(["x86_64"], expected: .arm64))
    }

    @Test func updaterUsesAnHourlyIntervalAndClampsDownloadProgress() {
        #expect(UpdateManager.automaticCheckInterval == 3_600)
        #expect(UpdateActivity.downloading(progress: -1).downloadProgress == 0)
        #expect(UpdateActivity.downloading(progress: 0.42).downloadProgress == 0.42)
        #expect(UpdateActivity.downloading(progress: 2).downloadProgress == 1)
        #expect(UpdateActivity.verifying.isBusy)
        #expect(!UpdateActivity.idle.isBusy)
    }

    @Test(arguments: ReleaseArchitecture.allCases)
    func installationHelperRequiresExactlyTheSelectedArchitecture(
        architecture: ReleaseArchitecture
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("install-update.zsh")
        let script = UpdateInstaller.installationHelperScript(expectedArchitecture: architecture)
        try Data(script.utf8).write(to: scriptURL)

        #expect(script.contains("expected_architecture=\"\(architecture.rawValue)\""))
        #expect(script.contains("\"$installed_archs\" != \"$expected_architecture\""))
        #expect(!script.contains("*\" arm64 \"*"))
        #expect(!script.contains("*\" x86_64 \"*"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", scriptURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func installationWatchdogForcesAStuckOldProcessToExit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-updater-watchdog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let readyURL = directory.appendingPathComponent("ready")
        let stubbornProcess = Process()
        stubbornProcess.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        stubbornProcess.arguments = [
            "-e",
            "$SIG{TERM} = 'IGNORE'; open(my $ready, '>', $ARGV[0]) or die $!; "
                + "print {$ready} 'ready'; close($ready); sleep 1 while 1;",
            readyURL.path,
        ]
        try stubbornProcess.run()
        defer {
            if stubbornProcess.isRunning {
                _ = kill(stubbornProcess.processIdentifier, SIGKILL)
            }
        }

        let readinessDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readinessDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))

        let scriptURL = directory.appendingPathComponent("watchdog.zsh")
        let watchdog = UpdateInstaller.processExitWatchdogScript(
            gracefulExitAttempts: 1,
            terminationExitAttempts: 1,
            forcedExitAttempts: 5
        )
        let script = """
            #!/bin/zsh
            old_pid="\(stubbornProcess.processIdentifier)"
            old_executable="/usr/bin/perl"
            update_root="\(directory.path)"
            \(watchdog)
            """
        try Data(script.utf8).write(to: scriptURL)

        #expect(script.contains("/bin/kill -TERM \"$old_pid\""))
        #expect(script.contains("/bin/kill -KILL \"$old_pid\""))
        #expect(script.contains("running_executable=$(/bin/ps -p \"$old_pid\" -o comm="))

        let watchdogOutputURL = directory.appendingPathComponent("watchdog-output.log")
        FileManager.default.createFile(atPath: watchdogOutputURL.path, contents: nil)
        let watchdogOutput = try FileHandle(forWritingTo: watchdogOutputURL)
        defer { try? watchdogOutput.close() }

        let watchdogProcess = Process()
        watchdogProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        watchdogProcess.arguments = [scriptURL.path]
        watchdogProcess.standardOutput = watchdogOutput
        watchdogProcess.standardError = watchdogOutput
        try watchdogProcess.run()

        let exitDeadline = Date().addingTimeInterval(5)
        while watchdogProcess.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if watchdogProcess.isRunning {
            watchdogProcess.terminate()
        }
        watchdogProcess.waitUntilExit()
        try watchdogOutput.close()
        let output = try String(contentsOf: watchdogOutputURL, encoding: .utf8)

        #expect(watchdogProcess.terminationStatus == 0)
        #expect(output.contains("sending TERM"))
        #expect(output.contains("sending KILL"))
        let stubbornProcessExited = waitUntil(timeout: 2) { !stubbornProcess.isRunning }
        #expect(stubbornProcessExited)
        if stubbornProcessExited {
            stubbornProcess.waitUntilExit()
            #expect(stubbornProcess.terminationReason == .uncaughtSignal)
            #expect(stubbornProcess.terminationStatus == SIGKILL)
        }
    }

    @Test func installationWatchdogDoesNotSignalAReusedPID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-updater-pid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelatedProcess.arguments = ["30"]
        try unrelatedProcess.run()
        defer {
            if unrelatedProcess.isRunning {
                unrelatedProcess.terminate()
            }
        }

        let scriptURL = directory.appendingPathComponent("watchdog.zsh")
        let script = """
            #!/bin/zsh
            old_pid="\(unrelatedProcess.processIdentifier)"
            old_executable="/Applications/VoiceInk.app/Contents/MacOS/VoiceInk"
            \(UpdateInstaller.processExitWatchdogScript(
                gracefulExitAttempts: 1,
                terminationExitAttempts: 1,
                forcedExitAttempts: 1
            ))
            """
        try Data(script.utf8).write(to: scriptURL)

        let watchdogProcess = Process()
        watchdogProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        watchdogProcess.arguments = [scriptURL.path]
        try watchdogProcess.run()
        watchdogProcess.waitUntilExit()

        #expect(watchdogProcess.terminationStatus == 0)
        #expect(unrelatedProcess.isRunning)
    }

    @Test(
        .enabled(if: FileManager.default.fileExists(atPath: artifactTestPathURL.path))
    )
    func installationHelperReplacesAndRelaunchesARealArtifact() throws {
        let environment = ProcessInfo.processInfo.environment
        let artifactPath = try String(contentsOf: Self.artifactTestPathURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!artifactPath.isEmpty)
        let artifact = URL(fileURLWithPath: artifactPath, isDirectory: true)
        let infoPlist = artifact.appendingPathComponent("Contents/Info.plist")
        let executable = artifact.appendingPathComponent("Contents/MacOS/VoiceInk")
        #expect(FileManager.default.fileExists(atPath: infoPlist.path))
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let version = try #require(
            Bundle(url: artifact)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-updater-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        let currentApp = testRoot.appendingPathComponent("Current/VoiceInk.app", isDirectory: true)
        let stagedApp = testRoot.appendingPathComponent("Staged/VoiceInk.app", isDirectory: true)
        let backupApp = testRoot.appendingPathComponent("Backup.app", isDirectory: true)
        let isolatedHome = testRoot.appendingPathComponent("Home", isDirectory: true)
        let logURL = testRoot.appendingPathComponent("update.log")
        let updateRoot = isolatedHome.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("VoiceInk/Updates", isDirectory: true)
            .appendingPathComponent("artifact-test-\(UUID().uuidString)", isDirectory: true)
        let markerURL = updateRoot.appendingPathComponent("launch-healthy")
        let helperURL = updateRoot.appendingPathComponent("install-update.zsh")
        let currentExecutable = currentApp.appendingPathComponent("Contents/MacOS/VoiceInk")

        try FileManager.default.createDirectory(
            at: currentApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stagedApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        try copyApp(artifact, to: currentApp)
        try copyApp(artifact, to: stagedApp)
        try Data(UpdateInstaller.installationHelperScript().utf8).write(to: helperURL)

        defer {
            terminateProcesses(executableURL: currentExecutable)
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: updateRoot)
        }

        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        oldProcess.arguments = [
            "-c",
            "trap '' TERM; exec \"$1\"",
            "artifact-test",
            currentExecutable.path,
        ]
        oldProcess.environment = environment.merging([
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path,
        ]) { _, isolated in isolated }
        try oldProcess.run()
        #expect(waitUntil(timeout: 5) {
            processIDs(executableURL: currentExecutable).contains(oldProcess.processIdentifier)
        })

        let helperProcess = Process()
        helperProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helperProcess.arguments = [
            helperURL.path,
            String(oldProcess.processIdentifier),
            currentApp.path,
            stagedApp.path,
            backupApp.path,
            markerURL.path,
            updateRoot.path,
            logURL.path,
            version,
        ]
        helperProcess.environment = oldProcess.environment
        try helperProcess.run()
        helperProcess.waitUntilExit()
        oldProcess.waitUntilExit()

        #expect(helperProcess.terminationStatus == 0)
        #expect(oldProcess.terminationReason == .uncaughtSignal)
        #expect(oldProcess.terminationStatus == SIGKILL)
        #expect(FileManager.default.fileExists(atPath: currentApp.path))
        #expect(!FileManager.default.fileExists(atPath: backupApp.path))
        #expect(!FileManager.default.fileExists(atPath: updateRoot.path))
        #expect(try String(contentsOf: logURL, encoding: .utf8).contains("sending KILL"))
        #expect(waitUntil(timeout: 5) { !processIDs(executableURL: currentExecutable).isEmpty })
    }

    private func copyApp(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func processIDs(executableURL: URL) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        process.standardOutput = output
        guard (try? process.run()) != nil else {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        guard let expectedIdentity = fileIdentity(atPath: executableURL.path) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                fileIdentity(atPath: String(fields[1])) == expectedIdentity,
                let pid = pid_t(String(fields[0]))
            else {
                return nil
            }
            return pid
        }
    }

    private func fileIdentity(atPath path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            return nil
        }
        return "\(device):\(inode)"
    }

    private func terminateProcesses(executableURL: URL) {
        for pid in processIDs(executableURL: executableURL) {
            _ = kill(pid, SIGKILL)
        }
    }
}
