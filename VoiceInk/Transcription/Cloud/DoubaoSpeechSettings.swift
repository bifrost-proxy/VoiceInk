import Foundation

struct DoubaoSpeechSettings: Equatable, Sendable {
    enum Keys {
        static let enableTwoPassRecognition = "DoubaoSpeechEnableTwoPassRecognition"
        static let enableTextNormalization = "DoubaoSpeechEnableTextNormalization"
        static let enablePunctuation = "DoubaoSpeechEnablePunctuation"
        static let enableSemanticSmoothing = "DoubaoSpeechEnableSemanticSmoothing"
        static let enableFirstTextAcceleration = "DoubaoSpeechEnableFirstTextAcceleration"
        static let firstTextAccelerationLevel = "DoubaoSpeechFirstTextAccelerationLevel"
        static let silenceFinalizationMilliseconds = "DoubaoSpeechSilenceFinalizationMilliseconds"
    }

    static let accelerationLevelRange = 0...20
    static let silenceFinalizationRange = 300...5_000

    static let defaults = DoubaoSpeechSettings(
        enableTwoPassRecognition: true,
        enableTextNormalization: true,
        enablePunctuation: true,
        enableSemanticSmoothing: false,
        enableFirstTextAcceleration: false,
        firstTextAccelerationLevel: 0,
        silenceFinalizationMilliseconds: 800
    )

    let enableTwoPassRecognition: Bool
    let enableTextNormalization: Bool
    let enablePunctuation: Bool
    let enableSemanticSmoothing: Bool
    let enableFirstTextAcceleration: Bool
    let firstTextAccelerationLevel: Int
    let silenceFinalizationMilliseconds: Int

    init(
        enableTwoPassRecognition: Bool,
        enableTextNormalization: Bool,
        enablePunctuation: Bool,
        enableSemanticSmoothing: Bool,
        enableFirstTextAcceleration: Bool,
        firstTextAccelerationLevel: Int,
        silenceFinalizationMilliseconds: Int
    ) {
        self.enableTwoPassRecognition = enableTwoPassRecognition
        self.enableTextNormalization = enableTextNormalization
        self.enablePunctuation = enablePunctuation
        self.enableSemanticSmoothing = enableSemanticSmoothing
        self.enableFirstTextAcceleration = enableFirstTextAcceleration
        self.firstTextAccelerationLevel = Self.accelerationLevelRange.clamped(firstTextAccelerationLevel)
        self.silenceFinalizationMilliseconds = Self.silenceFinalizationRange.clamped(
            silenceFinalizationMilliseconds)
    }

    static func current(in defaults: UserDefaults = .standard) -> DoubaoSpeechSettings {
        DoubaoSpeechSettings(
            enableTwoPassRecognition: bool(
                forKey: Keys.enableTwoPassRecognition,
                fallback: Self.defaults.enableTwoPassRecognition,
                in: defaults
            ),
            enableTextNormalization: bool(
                forKey: Keys.enableTextNormalization,
                fallback: Self.defaults.enableTextNormalization,
                in: defaults
            ),
            enablePunctuation: bool(
                forKey: Keys.enablePunctuation,
                fallback: Self.defaults.enablePunctuation,
                in: defaults
            ),
            enableSemanticSmoothing: bool(
                forKey: Keys.enableSemanticSmoothing,
                fallback: Self.defaults.enableSemanticSmoothing,
                in: defaults
            ),
            enableFirstTextAcceleration: bool(
                forKey: Keys.enableFirstTextAcceleration,
                fallback: Self.defaults.enableFirstTextAcceleration,
                in: defaults
            ),
            firstTextAccelerationLevel: integer(
                forKey: Keys.firstTextAccelerationLevel,
                fallback: Self.defaults.firstTextAccelerationLevel,
                in: defaults
            ),
            silenceFinalizationMilliseconds: integer(
                forKey: Keys.silenceFinalizationMilliseconds,
                fallback: Self.defaults.silenceFinalizationMilliseconds,
                in: defaults
            )
        )
    }

    private static func bool(forKey key: String, fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func integer(forKey key: String, fallback: Int, in defaults: UserDefaults) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
