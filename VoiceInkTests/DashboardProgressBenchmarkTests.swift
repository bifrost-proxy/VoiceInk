import Foundation
import Testing

@testable import VoiceInk

@Suite("Chinese literary milestones")
struct DashboardProgressBenchmarkTests {
    @Test(arguments: DashboardProgressBenchmark.milestones.indices)
    func everyBoundary(index: Int) {
        let milestone = DashboardProgressBenchmark.milestones[index]
        let before = DashboardProgressBenchmark.progress(for: milestone.count - 1)
        #expect(before.next == milestone)
        #expect(
            before.achieved == (index == 0 ? nil : DashboardProgressBenchmark.milestones[index - 1])
        )
        let exact = DashboardProgressBenchmark.progress(for: milestone.count)
        #expect(exact.achieved == milestone)
        #expect(exact.next.map { $0.count > milestone.count } == true)
        #expect(DashboardProgressBenchmark.progress(for: milestone.count + 1).achieved == milestone)
    }

    @Test func combinationsAndRepeatedSets() {
        let total = DashboardProgressBenchmark.completeSetCount
        #expect(total == 3_070_000)
        #expect(DashboardProgressBenchmark.progress(for: 900_000).achieved?.title == .waterMargin)
        #expect(DashboardProgressBenchmark.progress(for: 900_000).next?.count == 1_320_000)
        #expect(
            DashboardProgressBenchmark.progress(for: 2_220_000).achieved?.title == .threeClassics)
        #expect(
            DashboardProgressBenchmark.progress(for: total - 1).achieved?.title != .fourClassics)
        #expect(DashboardProgressBenchmark.progress(for: 2 * total - 1).achieved?.sets == 1)
        #expect(DashboardProgressBenchmark.progress(for: 2 * total).achieved?.sets == 2)
        #expect(DashboardProgressBenchmark.progress(for: 3 * total).next?.sets == 4)
        #expect(
            DashboardProgressBenchmark.progress(for: -1)
                == DashboardProgressBenchmark.progress(for: 0))
        let maximum = DashboardProgressBenchmark.progress(for: Int.max)
        #expect(maximum.achieved != nil)
        #expect(maximum.next == nil)
    }

    @Test func progressUsesTotalTowardNextBook() {
        let result = DashboardProgressBenchmark.progress(for: 82_200)
        #expect(result.achieved?.title == .callToArms)
        #expect(result.next?.title == .rickshawBoy)
        #expect(abs(result.fraction - 82_200.0 / 140_000) < 0.000001)
    }

    @Test(arguments: ["en", "zh-Hans", "de"])
    func localizedCopy(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let copy = DashboardBenchmarkCopy(bundle: bundle, locale: Locale(identifier: language))
        let summary = copy.summary(count: 82_200)
        let next = try #require(copy.nextTarget(count: 139_999))
        #expect(!summary.contains("%@"))
        #expect(!next.contains("100%"))
        #expect(copy.nextTarget(count: Int.max) == nil)
        #expect(
            copy.explanation(hasLegacyCounts: true).count
                > copy.explanation(hasLegacyCounts: false).count
        )
        for milestone in DashboardProgressBenchmark.milestones {
            #expect(!copy.title(milestone).isEmpty)
            if language == "zh-Hans" { #expect(copy.title(milestone) != milestone.title.rawValue) }
        }
        let repeated = copy.summary(count: 6_140_000)
        if language == "zh-Hans" {
            #expect(summary == "累计听写 8.22万字，篇幅约相当于《呐喊》。")
            #expect(next.contains("《骆驼祥子》"))
            #expect(repeated.contains("2 整套四大名著"))
            #expect(copy.formattedCount(100_000_000) == "1亿")
        } else if language == "en" {
            #expect(summary.contains("Call to Arms"))
            #expect(summary.contains("82.2K words / characters"))
            #expect(repeated.contains("2 complete sets"))
        }
    }
}
