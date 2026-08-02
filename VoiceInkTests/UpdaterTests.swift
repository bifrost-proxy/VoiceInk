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

        let release = try UpdateService.decodeAtomFeed(Data(feed.utf8))
        #expect(release.version == "2.3.0")
        #expect(
            release.archiveURL.absoluteString
                == "https://github.com/bifrost-proxy/VoiceInk/releases/download/v2.3.0/VoiceInk.zip"
        )
        #expect(
            release.checksumURL.absoluteString
                == "https://github.com/bifrost-proxy/VoiceInk/releases/download/v2.3.0/SHA256SUMS"
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

    @Test func checksumManifestRequiresTheExactVoiceInkArchive() throws {
        let expected = String(repeating: "a", count: 64)
        let manifest = """
            \(String(repeating: "b", count: 64))  Other.zip
            \(expected)  VoiceInk.zip
            """

        #expect(try UpdateService.checksum(for: "VoiceInk.zip", in: Data(manifest.utf8)) == expected)
        #expect(throws: UpdateService.Failure.self) {
            _ = try UpdateService.checksum(for: "Missing.zip", in: Data(manifest.utf8))
        }
    }

    @Test func updaterUsesAnHourlyIntervalAndClampsDownloadProgress() {
        #expect(UpdateManager.automaticCheckInterval == 3_600)
        #expect(UpdateActivity.downloading(progress: -1).downloadProgress == 0)
        #expect(UpdateActivity.downloading(progress: 0.42).downloadProgress == 0.42)
        #expect(UpdateActivity.downloading(progress: 2).downloadProgress == 1)
        #expect(UpdateActivity.verifying.isBusy)
        #expect(!UpdateActivity.idle.isBusy)
    }

    @Test func installationHelperHasValidZshSyntax() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("install-update.zsh")
        try Data(UpdateInstaller.installationHelperScript.utf8).write(to: scriptURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", scriptURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
