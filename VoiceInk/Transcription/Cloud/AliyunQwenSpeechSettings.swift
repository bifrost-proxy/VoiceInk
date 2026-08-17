import Foundation

enum AliyunQwenRegion: String, CaseIterable, Identifiable, Sendable {
    case beijing
    case singapore

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beijing: String(localized: "China (Beijing)")
        case .singapore: String(localized: "International (Singapore)")
        }
    }

    var sharedHost: String {
        switch self {
        case .beijing: "dashscope.aliyuncs.com"
        case .singapore: "dashscope-intl.aliyuncs.com"
        }
    }

    fileprivate var dedicatedHostSuffix: String {
        switch self {
        case .beijing: ".cn-beijing.maas.aliyuncs.com"
        case .singapore: ".ap-southeast-1.maas.aliyuncs.com"
        }
    }
}

enum AliyunQwenSettingsError: LocalizedError, Equatable {
    case invalidAPIHost
    case apiHostRegionMismatch

    var errorDescription: String? {
        switch self {
        case .invalidAPIHost:
            String(localized: "Enter a valid Alibaba Cloud Model Studio API host using HTTPS or WSS.")
        case .apiHostRegionMismatch:
            String(localized: "The API host does not match the selected Alibaba Cloud region.")
        }
    }
}

struct AliyunQwenSpeechSettings: Equatable, Sendable {
    enum Keys {
        static let region = "AliyunQwenRegion"
        static let apiHost = "AliyunQwenAPIHost"
        static let semanticPunctuationEnabled = "AliyunQwenSemanticPunctuationEnabled"
        static let maxSentenceSilenceMilliseconds = "AliyunQwenMaxSentenceSilenceMilliseconds"
        static let multiThresholdModeEnabled = "AliyunQwenMultiThresholdModeEnabled"
        static let heartbeatEnabled = "AliyunQwenHeartbeatEnabled"
        static let speechNoiseThresholdEnabled = "AliyunQwenSpeechNoiseThresholdEnabled"
        static let speechNoiseThreshold = "AliyunQwenSpeechNoiseThreshold"
        static let useVoiceInkVocabulary = "AliyunQwenUseVoiceInkVocabulary"
        static let vocabularyWeight = "AliyunQwenVocabularyWeight"
        static let contextPrompt = "AliyunQwenContextPrompt"
    }

    static let sentenceSilenceRange = 200...6_000
    static let vocabularyWeightRange = 1...5
    static let speechNoiseThresholdRange = -1.0...1.0
    static let maximumContextLength = 400

    static let defaults = AliyunQwenSpeechSettings(
        region: .beijing,
        apiHost: "",
        semanticPunctuationEnabled: false,
        maxSentenceSilenceMilliseconds: 1_300,
        multiThresholdModeEnabled: false,
        heartbeatEnabled: true,
        speechNoiseThresholdEnabled: false,
        speechNoiseThreshold: 0,
        useVoiceInkVocabulary: true,
        vocabularyWeight: 4,
        contextPrompt: ""
    )

    let region: AliyunQwenRegion
    let apiHost: String
    let semanticPunctuationEnabled: Bool
    let maxSentenceSilenceMilliseconds: Int
    let multiThresholdModeEnabled: Bool
    let heartbeatEnabled: Bool
    let speechNoiseThresholdEnabled: Bool
    let speechNoiseThreshold: Double
    let useVoiceInkVocabulary: Bool
    let vocabularyWeight: Int
    let contextPrompt: String

    init(
        region: AliyunQwenRegion,
        apiHost: String,
        semanticPunctuationEnabled: Bool,
        maxSentenceSilenceMilliseconds: Int,
        multiThresholdModeEnabled: Bool,
        heartbeatEnabled: Bool,
        speechNoiseThresholdEnabled: Bool,
        speechNoiseThreshold: Double,
        useVoiceInkVocabulary: Bool,
        vocabularyWeight: Int,
        contextPrompt: String
    ) {
        self.region = region
        self.apiHost = apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.semanticPunctuationEnabled = semanticPunctuationEnabled
        self.maxSentenceSilenceMilliseconds = Self.sentenceSilenceRange.clamped(
            maxSentenceSilenceMilliseconds
        )
        self.multiThresholdModeEnabled = semanticPunctuationEnabled ? false : multiThresholdModeEnabled
        self.heartbeatEnabled = heartbeatEnabled
        self.speechNoiseThresholdEnabled = speechNoiseThresholdEnabled
        self.speechNoiseThreshold = Self.speechNoiseThresholdRange.clamped(speechNoiseThreshold)
        self.useVoiceInkVocabulary = useVoiceInkVocabulary
        self.vocabularyWeight = Self.vocabularyWeightRange.clamped(vocabularyWeight)
        self.contextPrompt = String(contextPrompt.prefix(Self.maximumContextLength))
    }

    static func current(in defaults: UserDefaults = .standard) -> AliyunQwenSpeechSettings {
        let storedRegion = defaults.string(forKey: Keys.region)
            .flatMap(AliyunQwenRegion.init(rawValue:)) ?? Self.defaults.region

        return AliyunQwenSpeechSettings(
            region: storedRegion,
            apiHost: defaults.string(forKey: Keys.apiHost) ?? Self.defaults.apiHost,
            semanticPunctuationEnabled: bool(
                forKey: Keys.semanticPunctuationEnabled,
                fallback: Self.defaults.semanticPunctuationEnabled,
                in: defaults
            ),
            maxSentenceSilenceMilliseconds: integer(
                forKey: Keys.maxSentenceSilenceMilliseconds,
                fallback: Self.defaults.maxSentenceSilenceMilliseconds,
                in: defaults
            ),
            multiThresholdModeEnabled: bool(
                forKey: Keys.multiThresholdModeEnabled,
                fallback: Self.defaults.multiThresholdModeEnabled,
                in: defaults
            ),
            heartbeatEnabled: bool(
                forKey: Keys.heartbeatEnabled,
                fallback: Self.defaults.heartbeatEnabled,
                in: defaults
            ),
            speechNoiseThresholdEnabled: bool(
                forKey: Keys.speechNoiseThresholdEnabled,
                fallback: Self.defaults.speechNoiseThresholdEnabled,
                in: defaults
            ),
            speechNoiseThreshold: double(
                forKey: Keys.speechNoiseThreshold,
                fallback: Self.defaults.speechNoiseThreshold,
                in: defaults
            ),
            useVoiceInkVocabulary: bool(
                forKey: Keys.useVoiceInkVocabulary,
                fallback: Self.defaults.useVoiceInkVocabulary,
                in: defaults
            ),
            vocabularyWeight: integer(
                forKey: Keys.vocabularyWeight,
                fallback: Self.defaults.vocabularyWeight,
                in: defaults
            ),
            contextPrompt: defaults.string(forKey: Keys.contextPrompt) ?? Self.defaults.contextPrompt
        )
    }

    func webSocketURL() throws -> URL {
        let value = apiHost.isEmpty ? region.sharedHost : apiHost
        let candidate = value.contains("://") ? value : "wss://\(value)"
        guard
            let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "wss",
            let host = components.host?.lowercased(),
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil,
            Self.supportedConsolePaths.contains(Self.normalizedPath(components.path))
        else {
            throw AliyunQwenSettingsError.invalidAPIHost
        }

        let validSharedHost = host == region.sharedHost
        let validDedicatedHost = host.hasSuffix(region.dedicatedHostSuffix)
            && host.count > region.dedicatedHostSuffix.count
        guard validSharedHost || validDedicatedHost else {
            let isKnownAliyunHost = host == AliyunQwenRegion.beijing.sharedHost
                || host == AliyunQwenRegion.singapore.sharedHost
                || AliyunQwenRegion.allCases.contains { host.hasSuffix($0.dedicatedHostSuffix) }
            throw isKnownAliyunHost
                ? AliyunQwenSettingsError.apiHostRegionMismatch
                : AliyunQwenSettingsError.invalidAPIHost
        }

        var output = URLComponents()
        output.scheme = "wss"
        output.host = host
        output.path = "/api-ws/v1/inference"
        guard let url = output.url else {
            throw AliyunQwenSettingsError.invalidAPIHost
        }
        return url
    }

    private static let supportedConsolePaths: Set<String> = [
        "",
        "/api-ws/v1/inference",
        "/api/v1",
        "/compatible-mode/v1",
    ]

    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path == "/" ? "" : path }
        return String(path.dropLast())
    }

    private static func bool(forKey key: String, fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func integer(forKey key: String, fallback: Int, in defaults: UserDefaults) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private static func double(forKey key: String, fallback: Double, in defaults: UserDefaults) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
}

private extension ClosedRange where Bound: Comparable {
    func clamped(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
