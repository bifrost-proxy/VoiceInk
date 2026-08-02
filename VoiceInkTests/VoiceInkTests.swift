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
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("onboardingStage"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("NSWindow Frame main"))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey("CloudConfigurationSync.deviceID"))
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
            "sensevoice-small",
            "paraformer-large-zh",
            "qwen3-asr-0.6b-int8",
        ]

        for name in expectedNames {
            let model = TranscriptionModelRegistry.models.first { $0.name == name }
            #expect(model?.supportsStreaming == true, "Missing realtime preview support: \(name)")
        }

        #expect(TranscriptionModelRegistry.models.contains { $0.name == "parakeet-ctc-0.6b-zh-cn" } == false)
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
