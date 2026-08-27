import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct RecordingDurationLimitTests {
    @Test func defaultsToFiveMinutesAndClampsStoredValues() throws {
        let suiteName = "VoiceInkTests.RecordingDurationLimit"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        AppDefaults.registerDefaults(in: defaults)

        #expect(RecordingDurationSettings.currentMinutes(in: defaults) == 5)

        defaults.set(-4, forKey: RecordingDurationSettings.maximumRecordingMinutesKey)
        #expect(RecordingDurationSettings.currentMinutes(in: defaults) == 1)
        #expect(defaults.integer(forKey: RecordingDurationSettings.maximumRecordingMinutesKey) == 1)

        defaults.set(42, forKey: RecordingDurationSettings.maximumRecordingMinutesKey)
        #expect(RecordingDurationSettings.currentMinutes(in: defaults) == 10)
        #expect(defaults.integer(forKey: RecordingDurationSettings.maximumRecordingMinutesKey) == 10)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func appDefaultsHideDockIconByDefaultWithoutOverridingExplicitChoice() throws {
        let suiteName = "VoiceInkTests.DockDefault.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppDefaults.registerDefaults(in: defaults)
        #expect(defaults.bool(forKey: "IsMenuBarOnly"))

        defaults.set(false, forKey: "IsMenuBarOnly")
        AppDefaults.registerDefaults(in: defaults)
        #expect(!defaults.bool(forKey: "IsMenuBarOnly"))
    }

    @Test func productSafetyCapNeverExceedsTenMinutes() {
        #expect(RecordingDurationLimiter.clampedDuration(.seconds(-5)) == .zero)
        #expect(RecordingDurationLimiter.clampedDuration(.seconds(60)) == .seconds(60))
        #expect(RecordingDurationLimiter.clampedDuration(.seconds(3_600)) == .seconds(600))
    }

    @Test func durationPreferenceIsEligibleForPortableConfigurationSync() {
        #expect(
            CloudConfigurationSyncService.isEligiblePreferenceKey(
                RecordingDurationSettings.maximumRecordingMinutesKey
            )
        )
    }

    @Test func limiterFiresForTheScheduledRecording() async throws {
        let limiter = RecordingDurationLimiter()
        let recordingID = UUID()
        var reachedRecordingIDs: [UUID] = []

        limiter.schedule(recordingID: recordingID, duration: .milliseconds(10)) { reachedRecordingID in
            reachedRecordingIDs.append(reachedRecordingID)
        }
        try await Task.sleep(for: .milliseconds(80))

        #expect(reachedRecordingIDs == [recordingID])
        #expect(limiter.scheduledRecordingID == nil)
    }

    @Test func cancelPreventsAStaleRecordingFromStopping() async throws {
        let limiter = RecordingDurationLimiter()
        var didReachLimit = false

        limiter.schedule(recordingID: UUID(), duration: .milliseconds(10)) { _ in
            didReachLimit = true
        }
        limiter.cancel()
        try await Task.sleep(for: .milliseconds(80))

        #expect(!didReachLimit)
        #expect(limiter.scheduledRecordingID == nil)
    }

    @Test func reschedulingReplacesThePreviousRecording() async throws {
        let limiter = RecordingDurationLimiter()
        let previousRecordingID = UUID()
        let currentRecordingID = UUID()
        var reachedRecordingIDs: [UUID] = []

        limiter.schedule(recordingID: previousRecordingID, duration: .milliseconds(10)) { recordingID in
            reachedRecordingIDs.append(recordingID)
        }
        limiter.schedule(recordingID: currentRecordingID, duration: .milliseconds(20)) { recordingID in
            reachedRecordingIDs.append(recordingID)
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(reachedRecordingIDs == [currentRecordingID])
    }
}
