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
        static let enablePOIFunctionCall = "DoubaoSpeechEnablePOIFunctionCall"
        static let poiCityName = "DoubaoSpeechPOICityName"
        static let enableMusicFunctionCall = "DoubaoSpeechEnableMusicFunctionCall"
        static let contextPrompt = "DoubaoSpeechContextPrompt"
        static let useSelectedTextContext = "DoubaoSpeechUseSelectedTextContext"
        static let useClipboardContext = "DoubaoSpeechUseClipboardContext"
        static let useApplicationContext = "DoubaoSpeechUseApplicationContext"
        static let useWindowTitleContext = "DoubaoSpeechUseWindowTitleContext"
        static let legacyUseScreenContext = "DoubaoSpeechUseScreenContext"
        static let keepConnectionReady = "DoubaoSpeechKeepConnectionReady"
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
        silenceFinalizationMilliseconds: 800,
        enablePOIFunctionCall: false,
        poiCityName: "",
        enableMusicFunctionCall: false,
        contextPrompt: "",
        useSelectedTextContext: false,
        useClipboardContext: false,
        useApplicationContext: false,
        useWindowTitleContext: false,
        keepConnectionReady: false
    )

    let enableTwoPassRecognition: Bool
    let enableTextNormalization: Bool
    let enablePunctuation: Bool
    let enableSemanticSmoothing: Bool
    let enableFirstTextAcceleration: Bool
    let firstTextAccelerationLevel: Int
    let silenceFinalizationMilliseconds: Int
    let enablePOIFunctionCall: Bool
    let poiCityName: String
    let enableMusicFunctionCall: Bool
    let contextPrompt: String
    let useSelectedTextContext: Bool
    let useClipboardContext: Bool
    let useApplicationContext: Bool
    let useWindowTitleContext: Bool
    let keepConnectionReady: Bool

    init(
        enableTwoPassRecognition: Bool,
        enableTextNormalization: Bool,
        enablePunctuation: Bool,
        enableSemanticSmoothing: Bool,
        enableFirstTextAcceleration: Bool,
        firstTextAccelerationLevel: Int,
        silenceFinalizationMilliseconds: Int,
        enablePOIFunctionCall: Bool = false,
        poiCityName: String = "",
        enableMusicFunctionCall: Bool = false,
        contextPrompt: String = "",
        useSelectedTextContext: Bool = false,
        useClipboardContext: Bool = false,
        useApplicationContext: Bool = false,
        useWindowTitleContext: Bool = false,
        keepConnectionReady: Bool = false
    ) {
        self.enableTwoPassRecognition = enableTwoPassRecognition
        self.enableTextNormalization = enableTextNormalization
        self.enablePunctuation = enablePunctuation
        self.enableSemanticSmoothing = enableSemanticSmoothing
        self.enableFirstTextAcceleration = enableFirstTextAcceleration
        self.firstTextAccelerationLevel = Self.accelerationLevelRange.clamped(firstTextAccelerationLevel)
        self.silenceFinalizationMilliseconds = Self.silenceFinalizationRange.clamped(
            silenceFinalizationMilliseconds)
        self.enablePOIFunctionCall = enablePOIFunctionCall
        self.poiCityName = poiCityName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.enableMusicFunctionCall = enableMusicFunctionCall
        self.contextPrompt = String(contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        self.useSelectedTextContext = useSelectedTextContext
        self.useClipboardContext = useClipboardContext
        self.useApplicationContext = useApplicationContext
        self.useWindowTitleContext = useWindowTitleContext
        self.keepConnectionReady = keepConnectionReady
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
            ),
            enablePOIFunctionCall: bool(
                forKey: Keys.enablePOIFunctionCall,
                fallback: Self.defaults.enablePOIFunctionCall,
                in: defaults
            ),
            poiCityName: defaults.string(forKey: Keys.poiCityName) ?? Self.defaults.poiCityName,
            enableMusicFunctionCall: bool(
                forKey: Keys.enableMusicFunctionCall,
                fallback: Self.defaults.enableMusicFunctionCall,
                in: defaults
            ),
            contextPrompt: defaults.string(forKey: Keys.contextPrompt) ?? Self.defaults.contextPrompt,
            useSelectedTextContext: bool(
                forKey: Keys.useSelectedTextContext,
                fallback: Self.defaults.useSelectedTextContext,
                in: defaults
            ),
            useClipboardContext: bool(
                forKey: Keys.useClipboardContext,
                fallback: Self.defaults.useClipboardContext,
                in: defaults
            ),
            useApplicationContext: bool(
                forKey: Keys.useApplicationContext,
                fallback: Self.defaults.useApplicationContext,
                in: defaults
            ),
            useWindowTitleContext: bool(
                forKey: Keys.useWindowTitleContext,
                fallback: Self.defaults.useWindowTitleContext,
                in: defaults
            ),
            keepConnectionReady: bool(
                forKey: Keys.keepConnectionReady,
                fallback: Self.defaults.keepConnectionReady,
                in: defaults
            )
        )
    }

    var recognitionContextPermissions: RecognitionContextPermissions {
        RecognitionContextPermissions(
            selectedText: useSelectedTextContext,
            clipboard: useClipboardContext,
            application: useApplicationContext,
            windowTitle: useWindowTitleContext
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
