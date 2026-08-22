import Darwin
import Foundation
import Testing
@testable import VoiceInk

struct UpdaterTests {
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
        stubbornProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        stubbornProcess.arguments = [
            "-c",
            "trap '' TERM; print -r -- ready > \"$1\"; while true; do /bin/sleep 1; done",
            "watchdog-test",
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
            old_executable="/bin/zsh"
            update_root="\(directory.path)"
            \(watchdog)
            """
        try Data(script.utf8).write(to: scriptURL)

        #expect(script.contains("/bin/kill -TERM \"$old_pid\""))
        #expect(script.contains("/bin/kill -KILL \"$old_pid\""))
        #expect(script.contains("running_executable=$(/bin/ps -p \"$old_pid\" -o comm="))

        let watchdogProcess = Process()
        watchdogProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        watchdogProcess.arguments = [scriptURL.path]
        try watchdogProcess.run()

        let exitDeadline = Date().addingTimeInterval(5)
        while watchdogProcess.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if watchdogProcess.isRunning {
            watchdogProcess.terminate()
        }
        watchdogProcess.waitUntilExit()

        #expect(watchdogProcess.terminationStatus == 0)
        #expect(!stubbornProcess.isRunning)
    }
}
