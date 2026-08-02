//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

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

}
