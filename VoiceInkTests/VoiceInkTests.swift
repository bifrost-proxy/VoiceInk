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

    @Test func volcanoArkUsesOpenAICompatibleChatEndpoint() {
        #expect(AIProvider.ark.baseURL == "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        #expect(AIProvider.ark.requiresAPIKey)
        #expect(AIProvider.ark.supportsEnhancement)
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
            ) == nil
        )
    }

    @Test func bundledChineseASRModelsAreDownloadableAndSelectable() {
        let models = TranscriptionModelRegistry.models
        let expectedNames = [
            "sensevoice-small",
            "paraformer-large-zh",
            "parakeet-ctc-0.6b-zh-cn",
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
