//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
import SwiftData
import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test func cloudAndRetentionDefaultsArePrivacyPreservingAndUnlimited() throws {
        let suiteName = "VoiceInkTests.SyncDefaults"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        AppDefaults.registerDefaults(in: defaults)

        #expect(defaults.bool(forKey: CloudSyncSettingsKeys.configurationSyncEnabled))
        #expect(!defaults.bool(forKey: CloudSyncSettingsKeys.usageDataSyncEnabled))
        #expect(!defaults.bool(forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled))
        #expect(defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryRecordCount) == 0)
        #expect(defaults.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes) == 0)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func transcriptionStagePerformanceRoundTripsThroughPersistedData() throws {
        var original = TranscriptionPerformanceSnapshot(executionMode: "nativeStreaming")
        original.streamingResolution = "providerFinal"
        original.connectionDuration = 0.21
        original.firstPartialLatency = 0.44
        original.firstCommitLatency = 0.83
        original.drainDuration = 0.12
        original.finalizationDuration = 0.09
        original.transcriptionDuration = 2.1
        original.postProcessingDuration = 0.08
        original.enhancementDuration = 0.7
        original.deliveryDuration = 0.03
        original.totalProcessingDuration = 2.9
        original.receivedChunks = 42
        original.sentChunks = 42
        original.droppedChunks = 0
        original.receivedBytes = 268_800
        original.sentBytes = 268_800
        let transcription = Transcription(text: "同步阶段性能", duration: 4.2)
        transcription.performanceSnapshot = original

        #expect(transcription.performanceData != nil)
        #expect(transcription.performanceSnapshot == original)

        let metric = SessionMetric(
            transcriptionId: transcription.id,
            wordCount: 8,
            audioDuration: 4.2,
            transcriptionModelName: "streaming-model",
            transcriptionDuration: 2.1,
            speedFactor: 2,
            modeName: nil,
            aiEnhancementModelName: nil,
            enhancementDuration: 0.7,
            performanceData: transcription.performanceData
        )
        #expect(metric.performanceData == transcription.performanceData)
    }

    @Test func historyCapacityLimitsUseEitherThresholdAndDefaultToUnlimited() {
        #expect(
            !HistoryStorageManager.shouldDelete(
                recordCount: 10_000,
                managedBytes: 100_000_000_000,
                maximumRecordCount: 0,
                maximumBytes: 0
            )
        )
        #expect(
            HistoryStorageManager.shouldDelete(
                recordCount: 501,
                managedBytes: 100,
                maximumRecordCount: 500,
                maximumBytes: 0
            )
        )
        #expect(
            HistoryStorageManager.shouldDelete(
                recordCount: 10,
                managedBytes: 1_024,
                maximumRecordCount: 500,
                maximumBytes: 1_000
            )
        )
    }

    @Test func cloudUsageSnapshotPreservesEveryPerformanceStage() throws {
        var performance = TranscriptionPerformanceSnapshot(executionMode: "slidingWindow")
        performance.connectionDuration = 0.4
        performance.firstPartialLatency = 0.8
        performance.transcriptionDuration = 1.7
        performance.postProcessingDuration = 0.06
        performance.enhancementDuration = 0.5
        performance.deliveryDuration = 0.02
        performance.totalProcessingDuration = 2.3
        performance.receivedChunks = 30
        performance.sentChunks = 30
        let performanceData = try JSONEncoder().encode(performance)
        let transcriptionID = UUID()
        let payload = CloudUsageDataSyncService.TranscriptionPayload(
            id: transcriptionID,
            text: "完整输入",
            enhancedText: "润色结果",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 3.5,
            transcriptionModelName: "Parakeet CTC 0.6B (中文)",
            aiEnhancementModelName: "qwen",
            promptName: "Polish",
            transcriptionDuration: 1.7,
            enhancementDuration: 0.5,
            deliveredText: "润色结果",
            finalEditedText: "最终修改",
            pasteTargetApplicationName: "Notes",
            pasteTargetBundleIdentifier: "com.apple.Notes",
            pasteTargetElementRole: "AXTextArea",
            pasteTrackingStatus: "completed",
            pasteStartedAt: nil,
            pasteTrackingFinishedAt: nil,
            postPasteEditHistoryData: nil,
            modeName: "中文",
            modeEmoji: "📝",
            transcriptionStatus: "completed",
            performanceData: performanceData
        )
        let snapshot = CloudUsageDataSyncService.Snapshot(
            schemaVersion: CloudUsageDataSyncService.Snapshot.currentSchemaVersion,
            revisionID: UUID(),
            sourceDeviceID: "test-mac",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010),
            transcription: payload,
            metric: nil,
            audio: nil
        )

        let data = try PropertyListEncoder().encode(snapshot)
        let decoded = try PropertyListDecoder().decode(CloudUsageDataSyncService.Snapshot.self, from: data)
        let decodedPerformanceData = try #require(decoded.transcription.performanceData)
        let decodedPerformance = try JSONDecoder().decode(
            TranscriptionPerformanceSnapshot.self,
            from: decodedPerformanceData
        )

        #expect(decoded == snapshot)
        #expect(decodedPerformance == performance)
    }

    @MainActor
    @Test func historyCapacityCleanupDeletesOldestRecordsFirst() async throws {
        let previousCount = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.maximumHistoryRecordCount)
        let previousStorage = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        defer {
            UserDefaults.standard.set(previousCount, forKey: CleanupSettingsKeys.maximumHistoryRecordCount)
            UserDefaults.standard.set(previousStorage, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)
        }
        UserDefaults.standard.set(2, forKey: CleanupSettingsKeys.maximumHistoryRecordCount)
        UserDefaults.standard.set(0, forKey: CleanupSettingsKeys.maximumHistoryStorageMegabytes)

        let schema = Schema([Transcription.self, SessionMetric.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let timestamps = [100.0, 200.0, 300.0]
        for (index, timestamp) in timestamps.enumerated() {
            let record = Transcription(text: "record-\(index)", duration: 1)
            record.timestamp = Date(timeIntervalSince1970: timestamp)
            context.insert(record)
        }
        try context.save()

        let result = await HistoryStorageManager.shared.enforceLimits(modelContext: context)
        let remaining = try context.fetch(
            FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\Transcription.timestamp)])
        )

        #expect(result.deletedRecordCount == 1)
        #expect(remaining.map(\.text) == ["record-1", "record-2"])
    }

    @MainActor
    @Test func cloudUsageSyncTransfersHistoryAndPerformanceBetweenDevices() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkUsageSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let suiteAName = "VoiceInkTests.UsageSync.A.\(UUID().uuidString)"
        let suiteBName = "VoiceInkTests.UsageSync.B.\(UUID().uuidString)"
        let defaultsA = try #require(UserDefaults(suiteName: suiteAName))
        let defaultsB = try #require(UserDefaults(suiteName: suiteBName))
        defer {
            defaultsA.removePersistentDomain(forName: suiteAName)
            defaultsB.removePersistentDomain(forName: suiteBName)
        }
        defaultsA.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        defaultsB.set(true, forKey: CloudSyncSettingsKeys.usageDataSyncEnabled)
        defaultsA.set(true, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)
        defaultsB.set(false, forKey: CloudSyncSettingsKeys.usageAudioSyncEnabled)

        let schema = Schema([Transcription.self, SessionMetric.self])
        let configurationA = ModelConfiguration(isStoredInMemoryOnly: true)
        let configurationB = ModelConfiguration(isStoredInMemoryOnly: true)
        let containerA = try ModelContainer(for: schema, configurations: [configurationA])
        let containerB = try ModelContainer(for: schema, configurations: [configurationB])

        var performance = TranscriptionPerformanceSnapshot(executionMode: "nativeStreaming")
        performance.firstPartialLatency = 0.35
        performance.finalizationDuration = 0.11
        performance.totalProcessingDuration = 1.6
        let sourceRecord = Transcription(text: "跨设备转录", duration: 2.4)
        let sourceAudioURL = temporaryRoot.appendingPathComponent("source.wav")
        try Data(repeating: 7, count: 4_096).write(to: sourceAudioURL)
        sourceRecord.audioFileURL = sourceAudioURL.absoluteString
        sourceRecord.transcriptionStatus = TranscriptionStatus.completed.rawValue
        sourceRecord.performanceSnapshot = performance
        containerA.mainContext.insert(sourceRecord)
        try containerA.mainContext.save()

        let serviceA = CloudUsageDataSyncService(
            defaults: defaultsA,
            iCloudDriveRootURL: temporaryRoot
        )
        serviceA.start(modelContext: containerA.mainContext)
        try await waitForUsageSync(serviceA)

        let serviceB = CloudUsageDataSyncService(
            defaults: defaultsB,
            iCloudDriveRootURL: temporaryRoot
        )
        serviceB.start(modelContext: containerB.mainContext)
        try await waitForUsageSync(serviceB)

        let imported = try #require(containerB.mainContext.fetch(FetchDescriptor<Transcription>()).first)
        #expect(imported.id == sourceRecord.id)
        #expect(imported.text == "跨设备转录")
        #expect(imported.performanceSnapshot == performance)

        // A device that opted out of downloading audio must still carry the
        // existing cloud descriptor when it publishes a later metadata copy.
        serviceB.syncNow()
        let recordDirectory = temporaryRoot
            .appendingPathComponent("VoiceInk/UsageData/v1/Records", isDirectory: true)
            .appendingPathComponent(sourceRecord.id.uuidString, isDirectory: true)
        let replicaTimeout = Date().addingTimeInterval(5)
        var snapshots: [CloudUsageDataSyncService.Snapshot] = []
        repeat {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: recordDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            snapshots = urls.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? PropertyListDecoder().decode(CloudUsageDataSyncService.Snapshot.self, from: data)
            }
            if snapshots.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < replicaTimeout
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.audio != nil })

        serviceA.setEnabled(false)
        serviceB.setEnabled(false)
    }

    @MainActor
    private func waitForUsageSync(_ service: CloudUsageDataSyncService) async throws {
        let timeout = Date().addingTimeInterval(5)
        while service.lastSyncedAt == nil && Date() < timeout {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(service.state == .synced)
        #expect(service.lastSyncedAt != nil)
    }

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
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(CloudSyncSettingsKeys.configurationSyncEnabled))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(CloudSyncSettingsKeys.usageDataSyncEnabled))
        #expect(!CloudConfigurationSyncService.isEligiblePreferenceKey(CloudSyncSettingsKeys.usageAudioSyncEnabled))
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
            "qwen3-asr-0.6b-mlx-int8-streaming",
            "qwen3-asr-0.6b-mlx-streaming",
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

        var pcm = [Int16.min.littleEndian, 0, Int16.max.littleEndian]
        let pcmData = pcm.withUnsafeMutableBytes { Data($0) }
        let converted = PCMAudioConverter.float32Samples(fromPCM16Data: pcmData)
        #expect(converted == [-1, 0, Float(Int16.max) / 32768])

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

        let qwen3MLXModels = TranscriptionModelRegistry.models.filter {
            $0.provider == .qwenMlx
        }
        #expect(qwen3MLXModels.count == 2)
        for qwen3MLX in qwen3MLXModels {
            #expect(qwen3MLX.supportedLanguages.count == 31) // 30 languages plus auto-detect.
            #expect(ModelLanguageSupportCatalog.languageCount(for: qwen3MLX) == 52)
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
        let onboardingModel = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["en-US"],
            supportsQwenMLX: true
        ).requiredTranscriptionModel
        #expect(onboardingModel?.name == StarterModeFactory.defaultTranscriptionModelName)
        #expect(onboardingModel?.supportedLanguages.keys.contains(where: { $0.hasPrefix("zh") }) == true)
    }

    @MainActor
    @Test func chineseOnboardingRecommendsQwenMLXINT8OnAppleSilicon() {
        let defaults = UserDefaults(suiteName: "VoiceInkTests.ChineseOnboarding")!
        defaults.removePersistentDomain(forName: "VoiceInkTests.ChineseOnboarding")

        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            supportsQwenMLX: true
        )

        #expect(coordinator.recommendedLocalTranscriptionModelName == "qwen3-asr-0.6b-mlx-int8-streaming")
        #expect(coordinator.requiredTranscriptionModel?.name == "qwen3-asr-0.6b-mlx-int8-streaming")
        #expect((coordinator.requiredTranscriptionModel as? QwenMLXModel)?.precision == .int8)
    }

    @MainActor
    @Test func chineseOnboardingRecommendationDoesNotReplaceAnExistingModelSelection() {
        let suiteName = "VoiceInkTests.ChineseOnboardingExistingSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("qwen3-asr-0.6b-mlx-streaming", forKey: "CurrentTranscriptionModel")

        _ = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh-Hans"],
            supportsQwenMLX: true
        )

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "qwen3-asr-0.6b-mlx-streaming")
    }

    @MainActor
    @Test func chineseOnboardingFallsBackWhenMLXIsUnavailable() {
        let defaults = UserDefaults(suiteName: "VoiceInkTests.ChineseOnboardingFallback")!
        defaults.removePersistentDomain(forName: "VoiceInkTests.ChineseOnboardingFallback")

        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            preferredLanguages: ["zh_CN"],
            supportsQwenMLX: false
        )

        #expect(coordinator.recommendedLocalTranscriptionModelName == StarterModeFactory.defaultTranscriptionModelName)
        #expect(coordinator.requiredTranscriptionModel?.name == StarterModeFactory.defaultTranscriptionModelName)
    }

}
