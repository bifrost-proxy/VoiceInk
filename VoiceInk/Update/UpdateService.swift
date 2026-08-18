import Foundation

struct VoiceInkRelease: Equatable, Sendable {
    let version: String
    let archiveURL: URL
    let checksumURL: URL
}

enum ReleaseArchitecture: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    static var current: ReleaseArchitecture {
        #if arch(arm64)
            return .arm64
        #elseif arch(x86_64)
            return .x86_64
        #else
            fatalError("VoiceInk releases do not support this CPU architecture.")
        #endif
    }
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = Int(parts[2]),
            major >= 0,
            minor >= 0,
            patch >= 0
        else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum UpdateService {
    enum Failure: LocalizedError {
        case invalidResponse
        case invalidRelease
        case missingChecksum
        case untrustedURL

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "The update server returned an invalid response.")
            case .invalidRelease:
                return String(localized: "No valid VoiceInk release was found.")
            case .missingChecksum:
                return String(localized: "The update checksum is missing or invalid.")
            case .untrustedURL:
                return String(localized: "The update download URL is not trusted.")
            }
        }
    }

    static let repository = "bifrost-proxy/VoiceInk"
    static let releaseArchitecture = ReleaseArchitecture.current
    static var archiveName: String { archiveName(for: releaseArchitecture) }
    static let checksumName = "SHA256SUMS"

    static func archiveName(for architecture: ReleaseArchitecture) -> String {
        "VoiceInk-\(architecture.rawValue).zip"
    }

    static var currentVersion: String {
        ProcessInfo.processInfo.environment["VOICEINK_UPDATE_CURRENT_VERSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    static var atomFeedURL: URL {
        if let value = ProcessInfo.processInfo.environment["VOICEINK_UPDATE_FEED_URL"],
            let url = URL(string: value)
        {
            return url
        }
        return URL(string: "https://github.com/\(repository)/releases.atom")!
    }

    static func fetchLatestRelease() async throws -> VoiceInkRelease {
        var request = URLRequest(url: atomFeedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("VoiceInk/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw Failure.invalidResponse
        }
        return try decodeAtomFeed(data, architecture: releaseArchitecture)
    }

    static func decodeAtomFeed(
        _ data: Data,
        architecture: ReleaseArchitecture = releaseArchitecture
    ) throws -> VoiceInkRelease {
        let archiveName = archiveName(for: architecture)
        let releases = try ReleaseAtomParser.parse(data).compactMap { entry -> VoiceInkRelease? in
            guard entry.tag.hasPrefix("v") else { return nil }
            let version = String(entry.tag.dropFirst())
            guard SemanticVersion(version) != nil else { return nil }

            let releaseURL = URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
            guard entry.releaseURL == releaseURL else { return nil }

            let base = "https://github.com/\(repository)/releases/download/v\(version)"
            guard let archiveURL = URL(string: "\(base)/\(archiveName)"),
                let checksumURL = URL(string: "\(base)/\(checksumName)"),
                isTrustedReleaseDownloadURL(archiveURL),
                isTrustedReleaseDownloadURL(checksumURL)
            else {
                return nil
            }
            return VoiceInkRelease(version: version, archiveURL: archiveURL, checksumURL: checksumURL)
        }

        guard let release = releases.max(by: {
            guard let lhs = SemanticVersion($0.version), let rhs = SemanticVersion($1.version) else {
                return false
            }
            return lhs < rhs
        }) else {
            throw Failure.invalidRelease
        }
        return release
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = SemanticVersion(candidate), let current = SemanticVersion(current) else {
            return false
        }
        return candidate > current
    }

    static func checksum(for fileName: String, in data: Data) throws -> String {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw Failure.missingChecksum
        }
        let validHex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                fields[1] == Substring(fileName),
                fields[0].count == 64,
                fields[0].unicodeScalars.allSatisfy(validHex.contains)
            else {
                continue
            }
            return fields[0].lowercased()
        }
        throw Failure.missingChecksum
    }

    static func isTrustedReleaseDownloadURL(_ url: URL) -> Bool {
        if ProcessInfo.processInfo.environment["VOICEINK_UPDATE_ALLOW_INSECURE_TEST_FEED"] == "1",
            url.host == "127.0.0.1" || url.host == "localhost"
        {
            return true
        }

        return url.scheme == "https"
            && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/")
    }
}
