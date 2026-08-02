import Foundation

extension ModeManager {
    func migratedModeConfigurationData(for configKey: String) -> Data? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: configKey) {
            return data
        }

        guard let legacyData = defaults.data(forKey: LegacyModeDataKey.configurations) else {
            return nil
        }

        defaults.set(legacyData, forKey: configKey)
        return legacyData
    }

    func migrateLoadedModeConfigurationsIfNeeded() {
        let defaults = UserDefaults.standard
        let bufferedRealtimeMigrationKey = "buffered-local-realtime-migrated-v1"
        let shouldMigrateBufferedRealtime = !defaults.bool(forKey: bufferedRealtimeMigrationKey)
        var didChange = false
        var foundBufferedRealtimeModel = false

        for index in configurations.indices {
            var config = configurations[index]
            var changedConfig = false

            let bufferedRealtimeMigration = BufferedRealtimeModeMigration.migrate(
                config,
                shouldMigrate: shouldMigrateBufferedRealtime
            )
            if bufferedRealtimeMigration.foundBufferedRealtimeModel {
                foundBufferedRealtimeModel = true
                if bufferedRealtimeMigration.configuration != config {
                    config = bufferedRealtimeMigration.configuration
                    changedConfig = true
                }
            }

            if config.selectedTranscriptionModelName == nil {
                config.selectedTranscriptionModelName = UserDefaults.standard.string(
                    forKey: "CurrentTranscriptionModel")
                changedConfig = true
            }

            if config.selectedLanguage == nil {
                config.selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
                changedConfig = true
            }

            if config.selectedAIProvider == nil {
                config.selectedAIProvider = UserDefaults.standard.string(forKey: "selectedAIProvider")
                changedConfig = true
            }

            if config.selectedAIModel == nil,
                let provider = config.selectedAIProvider
            {
                config.selectedAIModel = UserDefaults.standard.string(forKey: "\(provider)SelectedModel")
                changedConfig = true
            }

            if config.isAIEnhancementEnabled && config.selectedPrompt == nil {
                config.selectedPrompt = UserDefaults.standard.string(forKey: "selectedPromptId")
                changedConfig = true
            }

            if changedConfig {
                configurations[index] = config
                didChange = true
            }
        }

        if didChange {
            saveConfigurations()
        }

        if shouldMigrateBufferedRealtime && foundBufferedRealtimeModel {
            defaults.set(true, forKey: bufferedRealtimeMigrationKey)
        }

        migrateLegacyShortcutStorageIfNeeded()
    }
    private func migrateLegacyShortcutStorageIfNeeded() {
        let defaults = UserDefaults.standard

        for config in configurations {
            let oldShortcutKey = "\(LegacyModeDataKey.shortcutPrefix)\(config.id.uuidString)"
            let newShortcutKey = ShortcutAction.mode(config.id).userDefaultsKey

            if defaults.object(forKey: newShortcutKey) == nil,
                let oldShortcutData = defaults.data(forKey: oldShortcutKey)
            {
                defaults.set(oldShortcutData, forKey: newShortcutKey)
            }

            let oldClearedKey = "\(oldShortcutKey)_cleared"
            let newClearedKey = "\(newShortcutKey)_cleared"
            if defaults.object(forKey: newClearedKey) == nil,
                defaults.object(forKey: oldClearedKey) != nil
            {
                defaults.set(defaults.bool(forKey: oldClearedKey), forKey: newClearedKey)
            }
        }
    }
}

enum BufferedRealtimeModeMigration {
    static let modelNames: Set<String> = [
        "parakeet-ctc-0.6b-zh-cn",
        "sensevoice-small",
        "paraformer-large-zh",
        "qwen3-asr-0.6b-int8",
    ]

    static func migrate(
        _ configuration: ModeConfig,
        shouldMigrate: Bool
    ) -> (configuration: ModeConfig, foundBufferedRealtimeModel: Bool) {
        guard let modelName = configuration.selectedTranscriptionModelName,
            modelNames.contains(modelName)
        else {
            return (configuration, false)
        }

        var migratedConfiguration = configuration
        if shouldMigrate {
            migratedConfiguration.isRealtimeTranscriptionEnabled = true
        }
        return (migratedConfiguration, true)
    }
}

private enum LegacyModeDataKey {
    static let configurations = "powerModeConfigurationsV2"
    static let shortcutPrefix = "Shortcut_powerMode_"
}
