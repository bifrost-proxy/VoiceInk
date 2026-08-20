import Foundation
import Testing
@testable import VoiceInk

@Suite("Dashboard insight period preference")
struct DashboardInsightPeriodTests {
    @Test("Uses all time when no selection has been saved")
    func usesDefaultWhenMissing() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(DashboardInsightPeriod.stored(in: defaults) == .allTime)
    }

    @Test("Every insight period survives a preference round trip", arguments: DashboardInsightPeriod.allCases)
    func roundTripsEveryPeriod(period: DashboardInsightPeriod) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        period.store(in: defaults)

        #expect(DashboardInsightPeriod.stored(in: defaults) == period)
    }

    @Test("Falls back safely when a saved value is no longer valid")
    func fallsBackForInvalidValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-period", forKey: DashboardSettingsKeys.insightPeriod)

        #expect(DashboardInsightPeriod.stored(in: defaults) == .allTime)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "VoiceInkTests.DashboardInsightPeriod.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
