import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
    static let maximumHistoryRecordCount = "MaximumHistoryRecordCount"
    static let maximumHistoryStorageMegabytes = "MaximumHistoryStorageMegabytes"
    static let lastAutomaticHistoryCleanupDate = "HistoryCleanupLastAutomaticCheckDate"
    static let historyStorageLimitActivationDate = "HistoryStorageLimitActivationDate"
    static let historyStorageCapacityMigrationCompleted = "HistoryStorageCapacityMigrationCompleted"
}

enum HistoryStorageSettings {
    static let defaultMegabytes = 500
    static let allowedMegabytes = 100...102_400
    static let cleanupCheckInterval: TimeInterval = 60 * 60
    static let activationDelay: TimeInterval = 30

    static func normalizedMegabytes(_ megabytes: Int) -> Int {
        min(max(megabytes, allowedMegabytes.lowerBound), allowedMegabytes.upperBound)
    }

    @discardableResult
    static func currentMegabytes(in defaults: UserDefaults = .standard) -> Int {
        let storedMegabytes = defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        let normalizedMegabytes = storedMegabytes <= 0
            ? defaultMegabytes
            : normalizedMegabytes(storedMegabytes)
        if storedMegabytes != normalizedMegabytes {
            defaults.set(normalizedMegabytes, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        }
        return normalizedMegabytes
    }
}

enum CloudSyncSettingsKeys {
    static let configurationSyncEnabled = "CloudConfigurationSyncEnabled"
    static let usageDataSyncEnabled = "CloudUsageDataSyncEnabled"
    static let usageAudioSyncEnabled = "CloudUsageAudioSyncEnabled"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum DashboardSettingsKeys {
    static let insightPeriod = "DashboardInsightPeriod"
}

enum RecordingDurationSettings {
    static let maximumRecordingMinutesKey = "MaximumRecordingDurationMinutes"
    static let defaultMinutes = 5
    static let allowedMinutes = 1...10

    static func normalizedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, allowedMinutes.lowerBound), allowedMinutes.upperBound)
    }

    @discardableResult
    static func currentMinutes(in defaults: UserDefaults = .standard) -> Int {
        let storedMinutes = defaults.object(forKey: maximumRecordingMinutesKey) == nil
            ? defaultMinutes
            : defaults.integer(forKey: maximumRecordingMinutesKey)
        let normalizedMinutes = normalizedMinutes(storedMinutes)
        if storedMinutes != normalizedMinutes {
            defaults.set(normalizedMinutes, forKey: maximumRecordingMinutesKey)
        }
        return normalizedMinutes
    }
}

enum AppDefaults {
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            // Onboarding & General
            "hasCompletedOnboardingV2": false,
            "hasPreparedOnboardingV2": false,
            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,
            // Audio & Media
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,
            RecordingDurationSettings.maximumRecordingMinutesKey: RecordingDurationSettings.defaultMinutes,
            DoubaoSpeechSettings.Keys.enableTwoPassRecognition:
                DoubaoSpeechSettings.defaults.enableTwoPassRecognition,
            DoubaoSpeechSettings.Keys.enableTextNormalization:
                DoubaoSpeechSettings.defaults.enableTextNormalization,
            DoubaoSpeechSettings.Keys.enablePunctuation:
                DoubaoSpeechSettings.defaults.enablePunctuation,
            DoubaoSpeechSettings.Keys.enableSemanticSmoothing:
                DoubaoSpeechSettings.defaults.enableSemanticSmoothing,
            DoubaoSpeechSettings.Keys.enableFirstTextAcceleration:
                DoubaoSpeechSettings.defaults.enableFirstTextAcceleration,
            DoubaoSpeechSettings.Keys.firstTextAccelerationLevel:
                DoubaoSpeechSettings.defaults.firstTextAccelerationLevel,
            DoubaoSpeechSettings.Keys.silenceFinalizationMilliseconds:
                DoubaoSpeechSettings.defaults.silenceFinalizationMilliseconds,
            DoubaoSpeechSettings.Keys.enablePOIFunctionCall:
                DoubaoSpeechSettings.defaults.enablePOIFunctionCall,
            DoubaoSpeechSettings.Keys.poiCityName:
                DoubaoSpeechSettings.defaults.poiCityName,
            DoubaoSpeechSettings.Keys.enableMusicFunctionCall:
                DoubaoSpeechSettings.defaults.enableMusicFunctionCall,
            DoubaoSpeechSettings.Keys.contextPrompt:
                DoubaoSpeechSettings.defaults.contextPrompt,
            DoubaoSpeechSettings.Keys.useSelectedTextContext:
                DoubaoSpeechSettings.defaults.useSelectedTextContext,
            DoubaoSpeechSettings.Keys.useClipboardContext:
                DoubaoSpeechSettings.defaults.useClipboardContext,
            DoubaoSpeechSettings.Keys.useApplicationContext:
                DoubaoSpeechSettings.defaults.useApplicationContext,
            DoubaoSpeechSettings.Keys.useWindowTitleContext:
                DoubaoSpeechSettings.defaults.useWindowTitleContext,
            DoubaoSpeechSettings.Keys.keepConnectionReady:
                DoubaoSpeechSettings.defaults.keepConnectionReady,
            AliyunQwenSpeechSettings.Keys.region: AliyunQwenSpeechSettings.defaults.region.rawValue,
            AliyunQwenSpeechSettings.Keys.apiHost: AliyunQwenSpeechSettings.defaults.apiHost,
            AliyunQwenSpeechSettings.Keys.semanticPunctuationEnabled:
                AliyunQwenSpeechSettings.defaults.semanticPunctuationEnabled,
            AliyunQwenSpeechSettings.Keys.maxSentenceSilenceMilliseconds:
                AliyunQwenSpeechSettings.defaults.maxSentenceSilenceMilliseconds,
            AliyunQwenSpeechSettings.Keys.multiThresholdModeEnabled:
                AliyunQwenSpeechSettings.defaults.multiThresholdModeEnabled,
            AliyunQwenSpeechSettings.Keys.heartbeatEnabled:
                AliyunQwenSpeechSettings.defaults.heartbeatEnabled,
            AliyunQwenSpeechSettings.Keys.speechNoiseThresholdEnabled:
                AliyunQwenSpeechSettings.defaults.speechNoiseThresholdEnabled,
            AliyunQwenSpeechSettings.Keys.speechNoiseThreshold:
                AliyunQwenSpeechSettings.defaults.speechNoiseThreshold,
            AliyunQwenSpeechSettings.Keys.useVoiceInkVocabulary:
                AliyunQwenSpeechSettings.defaults.useVoiceInkVocabulary,
            AliyunQwenSpeechSettings.Keys.vocabularyWeight:
                AliyunQwenSpeechSettings.defaults.vocabularyWeight,
            AliyunQwenSpeechSettings.Keys.contextPrompt:
                AliyunQwenSpeechSettings.defaults.contextPrompt,
            AliyunQwenSpeechSettings.Keys.useSelectedTextContext:
                AliyunQwenSpeechSettings.defaults.useSelectedTextContext,
            AliyunQwenSpeechSettings.Keys.useClipboardContext:
                AliyunQwenSpeechSettings.defaults.useClipboardContext,
            AliyunQwenSpeechSettings.Keys.useApplicationContext:
                AliyunQwenSpeechSettings.defaults.useApplicationContext,
            AliyunQwenSpeechSettings.Keys.useWindowTitleContext:
                AliyunQwenSpeechSettings.defaults.useWindowTitleContext,
            AliyunQwenSpeechSettings.Keys.keepConnectionReady:
                AliyunQwenSpeechSettings.defaults.keepConnectionReady,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,
            CleanupSettingsKeys.maximumHistoryRecordCount: 0,
            CleanupSettingsKeys.maximumHistoryStorageMegabytes: HistoryStorageSettings.defaultMegabytes,

            // iCloud. Portable configuration keeps its existing opt-out
            // behavior; private usage history and audio require explicit opt-in.
            CloudSyncSettingsKeys.configurationSyncEnabled: true,
            CloudSyncSettingsKeys.usageDataSyncEnabled: false,
            CloudSyncSettingsKeys.usageAudioSyncEnabled: false,

            // UI & Behavior
            "IsMenuBarOnly": false,
            UpdateManager.automaticallyChecksKey: true,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Shortcuts
            "isMiddleClickToggleEnabled": false,
            "middleClickActivationDelay": 200,

            // Enhancement
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            "EnhancementTimeoutSeconds": 7,
            "EnhancementRetryOnTimeout": true,
            LocalCLIService.executionModeKey: LocalCLIExecutionMode.command.rawValue,
            LocalCLIService.timeoutSecondsKey: LocalCLIService.defaultTimeoutSeconds,
            LocalCLIService.codexModelKey: "",
            LocalCLIService.codexReasoningEffortKey: LocalCLIService.defaultCodexReasoningEffort,

            // Model
            "PrewarmModelOnWake": true,

        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
