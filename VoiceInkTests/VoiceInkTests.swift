//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @MainActor
    @Test func cloudConfigurationSyncExcludesSecretsAndDeviceState() {
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("Volcengine ArkSelectedModel"))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("modeConfigurationsV2"))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("customPrompts"))
        #expect(CloudConfigurationSyncService.isEligiblePreferenceKey("Shortcut_primaryRecording"))

        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("LocalKeychain_openAIAPIKey"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("selectedAudioDeviceUID"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("hasCompletedOnboardingV2"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("buffered-local-realtime-migrated-v1"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("onboardingStage"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("NSWindow Frame main"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("CloudConfigurationSync.deviceID"))
    }

    @MainActor
    @Test func cloudConfigurationSyncIgnoresRepeatedContentNotifications() {
        let original = CloudConfigurationSyncService.Content(
            preferences: ["mode": Data("original".utf8)],
            vocabulary: [],
            replacements: []
        )
        let changed = CloudConfigurationSyncService.Content(
            preferences: ["mode": Data("changed".utf8)],
            vocabulary: [],
            replacements: []
        )

        #expect(
            CloudConfigurationSyncService.shouldQueueLocalChange(
                current: changed,
                lastKnown: original,
                pending: nil
            )
        )
        #expect(
            !CloudConfigurationSyncService.shouldQueueLocalChange(
                current: changed,
                lastKnown: original,
                pending: changed
            )
        )
        #expect(
            !CloudConfigurationSyncService.shouldQueueLocalChange(
                current: original,
                lastKnown: original,
                pending: nil
            )
        )
    }

    @Test func volcanoArkUsesOpenAICompatibleChatEndpoint() {
        #expect(AIProvider.ark.baseURL == "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        #expect(AIProvider.ark.requiresAPIKey)
        #expect(AIProvider.ark.supportsEnhancement)
        #expect(!AIProvider.ark.isVerificationConfigured(hasAPIKey: true, model: ""))
        #expect(!AIProvider.ark.isVerificationConfigured(hasAPIKey: false, model: "ep-example"))
        #expect(AIProvider.ark.isVerificationConfigured(hasAPIKey: true, model: "ep-example"))
        #expect(AIProvider.openAI.isVerificationConfigured(hasAPIKey: true, model: ""))
    }

    @MainActor
    @Test func missingPromptStorageRestoresBuiltInPrompts() throws {
        let suiteName = "VoiceInkTests.MissingPrompts"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let restored = AIEnhancementService.loadPrompts(from: defaults)
        #expect(restored.first?.id == PromptTemplates.defaultPromptId)

        defaults.set(try JSONEncoder().encode([CustomPrompt]()), forKey: "customPrompts")
        #expect(AIEnhancementService.loadPrompts(from: defaults).isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func adHocPermissionResetCommandsTargetOnlyVoiceInk() {
        let bundleIdentifier = "com.prakashjoshipax.VoiceInk"

        #expect(
            PrivacyPermissionResetService.command(
                for: .accessibility,
                bundleIdentifier: bundleIdentifier
            ) == PrivacyPermissionResetCommand(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "Accessibility", bundleIdentifier]
            )
        )
        #expect(
            PrivacyPermissionResetService.command(
                for: .screenRecording,
                bundleIdentifier: bundleIdentifier
            ) == PrivacyPermissionResetCommand(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "ScreenCapture", bundleIdentifier]
            )
        )
        #expect(
            PrivacyPermissionResetService.command(
                for: .microphone,
                bundleIdentifier: bundleIdentifier
            ) == PrivacyPermissionResetCommand(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "Microphone", bundleIdentifier]
            )
        )
    }

    @Test func adHocPermissionRegistrationIsRequestedOncePerInstalledBuild() {
        #expect(
            PrivacyPermissionResetService.shouldAutomaticallyRequestPermission(
                isGranted: false,
                hasCompletedOnboarding: true,
                currentRegistrationIdentifier: "2.2.3-7",
                lastRequestedRegistrationIdentifier: "2.2.2-6"
            )
        )
        #expect(
            !PrivacyPermissionResetService.shouldAutomaticallyRequestPermission(
                isGranted: false,
                hasCompletedOnboarding: true,
                currentRegistrationIdentifier: "2.2.3-7",
                lastRequestedRegistrationIdentifier: "2.2.3-7"
            )
        )
        #expect(
            !PrivacyPermissionResetService.shouldAutomaticallyRequestPermission(
                isGranted: true,
                hasCompletedOnboarding: true,
                currentRegistrationIdentifier: "2.2.3-7",
                lastRequestedRegistrationIdentifier: "2.2.2-6"
            )
        )
        #expect(
            !PrivacyPermissionResetService.shouldAutomaticallyRequestPermission(
                isGranted: false,
                hasCompletedOnboarding: false,
                currentRegistrationIdentifier: "2.2.3-7",
                lastRequestedRegistrationIdentifier: nil
            )
        )
    }

    @Test func bundledChineseASRModelsAreDownloadableAndSelectable() {
        let models = TranscriptionModelRegistry.models
        let expectedNames = [
            "parakeet-ctc-0.6b-zh-cn",
            "sensevoice-small",
            "paraformer-large-zh",
            "qwen3-asr-0.6b-int8",
            "sherpa-zipformer-ctc-zh-int8",
            "ggml-small",
            "ggml-medium",
        ]

        for name in expectedNames {
            let model = models.first { $0.name == name }
            #expect(model != nil, "Missing bundled ASR model: \(name)")
            #expect(model?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)
            #expect(model?.language != "English", "Chinese ASR model is mislabeled as English: \(name)")
        }
    }

    @Test func bufferedLocalModelsExposeRealtimePreview() {
        let expectedNames = [
            "parakeet-ctc-0.6b-zh-cn",
            "sensevoice-small",
            "paraformer-large-zh",
            "qwen3-asr-0.6b-int8",
        ]

        for name in expectedNames {
            let model = TranscriptionModelRegistry.models.first { $0.name == name }
            #expect(model?.supportsStreaming == true, "Missing realtime preview support: \(name)")
        }

        let provider = BufferedOnDeviceStreamingProvider(
            backend: .funASR(FluidAudioTranscriptionService())
        )
        if case .finalizeStreaming = provider.stopDisposition {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "Buffered previews must finalize their last non-empty result")
        }

        let samples: [Float] = [0.1, -0.2, 0.3]
        let prepared = FluidAudioTranscriptionService.prepareSenseVoiceSamples(samples)
        #expect(Array(prepared.prefix(samples.count)) == samples)
        #expect(prepared.count == samples.count + 8_000)

        let qwen3 = TranscriptionModelRegistry.models.first { $0.name == "qwen3-asr-0.6b-int8" }
        #expect(qwen3 != nil)
        if let qwen3 {
            #expect(qwen3.supportedLanguages.count == 31) // 30 languages plus auto-detect.
            #expect(ModelLanguageSupportCatalog.languageCount(for: qwen3) == 52)
        }
    }

    @Test func postPasteTextChangeCapturesInsertedAndRemovedText() throws {
        let insertion = try #require(
            PostPasteTextChange.between("Hello world", "Hello VoiceInk world")
        )
        #expect(insertion.oldRange == NSRange(location: 6, length: 0))
        #expect(insertion.removedText.isEmpty)
        #expect(insertion.insertedText == "VoiceInk ")

        let replacement = try #require(
            PostPasteTextChange.between("Send the old draft", "Send the final draft")
        )
        #expect(replacement.removedText == "old")
        #expect(replacement.insertedText == "final")
    }

    @Test func postPasteTextChangeKeepsTrackedRangeAligned() throws {
        let insertionBefore = try #require(
            PostPasteTextChange.between("PrefixVoiceInk", "Long PrefixVoiceInk")
        )
        let shifted = insertionBefore.applying(
            to: NSRange(location: 6, length: 8),
            newTextUTF16Count: "Long PrefixVoiceInk".utf16.count
        )
        #expect(!shifted.affected)
        #expect(shifted.range == NSRange(location: 11, length: 8))

        let editInside = try #require(
            PostPasteTextChange.between("VoiceInk", "Voice Ink")
        )
        let expanded = editInside.applying(
            to: NSRange(location: 0, length: 8),
            newTextUTF16Count: "Voice Ink".utf16.count
        )
        #expect(expanded.affected)
        #expect(expanded.range == NSRange(location: 0, length: 9))
    }

    @MainActor
    @Test func starterAndOnboardingModelsSupportChinese() {
        let starter = TranscriptionModelRegistry.models.first {
            $0.name == StarterModeFactory.defaultTranscriptionModelName
        }
        #expect(starter != nil)
        #expect(starter?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)

        let defaults = UserDefaults(suiteName: "VoiceInkTests.Onboarding")!
        defaults.removePersistentDomain(forName: "VoiceInkTests.Onboarding")
        let onboardingModel = OnboardingCoordinator(defaults: defaults).requiredTranscriptionModel
        #expect(onboardingModel?.name == StarterModeFactory.defaultTranscriptionModelName)
        #expect(onboardingModel?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)
    }

}
