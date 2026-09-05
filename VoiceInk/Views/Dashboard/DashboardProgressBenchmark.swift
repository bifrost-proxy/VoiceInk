import Foundation

/// Fixed, approximate Chinese-original lengths; see docs/chinese-literary-milestones.md.
/// Language affects presentation only, never achievement thresholds.
enum DashboardProgressBenchmark {
    enum Title: String, CaseIterable {
        case thousandCharacterClassic = "Thousand Character Classic"
        case artOfWar = "The Art of War"
        case ahQ = "The True Story of Ah Q"
        case callToArms = "Call to Arms"
        case rickshawBoy = "Rickshaw Boy"
        case fortressBesieged = "Fortress Besieged"
        case threeKingdoms = "Romance of the Three Kingdoms"
        case journeyToTheWest = "Journey to the West"
        case dreamOfTheRedChamber = "Dream of the Red Chamber"
        case waterMargin = "Water Margin"
        case twoClassics = "Three Kingdoms + Journey to the West"
        case threeClassics = "Three Kingdoms + Journey to the West + Water Margin"
        case fourClassics = "the Four Great Classical Novels"
    }

    struct Milestone: Equatable {
        let title: Title
        let count: Int
        var sets: Int = 1
    }

    struct Progress: Equatable {
        let achieved: Milestone?
        let next: Milestone?
        let fraction: Double
    }

    static let threeKingdoms = Milestone(title: .threeKingdoms, count: 600_000)
    static let journeyToTheWest = Milestone(title: .journeyToTheWest, count: 720_000)
    static let dreamOfTheRedChamber = Milestone(title: .dreamOfTheRedChamber, count: 850_000)
    static let waterMargin = Milestone(title: .waterMargin, count: 900_000)
    static let completeSetCount =
        threeKingdoms.count + journeyToTheWest.count
        + dreamOfTheRedChamber.count + waterMargin.count

    static let milestones: [Milestone] = [
        Milestone(title: .thousandCharacterClassic, count: 1_000),
        Milestone(title: .artOfWar, count: 6_000),
        Milestone(title: .ahQ, count: 25_000),
        Milestone(title: .callToArms, count: 80_000),
        Milestone(title: .rickshawBoy, count: 140_000),
        Milestone(title: .fortressBesieged, count: 250_000),
        threeKingdoms, journeyToTheWest, dreamOfTheRedChamber, waterMargin,
        Milestone(title: .twoClassics, count: threeKingdoms.count + journeyToTheWest.count),
        Milestone(
            title: .threeClassics,
            count: threeKingdoms.count + journeyToTheWest.count + waterMargin.count
        ),
        Milestone(title: .fourClassics, count: completeSetCount),
    ]

    static func progress(for count: Int) -> Progress {
        let count = max(0, count)
        if count >= completeSetCount {
            let sets = count / completeSetCount
            let achieved = Milestone(
                title: .fourClassics, count: sets * completeSetCount, sets: sets)
            let (nextCount, overflow) = (sets + 1).multipliedReportingOverflow(by: completeSetCount)
            let next =
                overflow ? nil : Milestone(title: .fourClassics, count: nextCount, sets: sets + 1)
            return Progress(
                achieved: achieved, next: next,
                fraction: next.map { Double(count) / Double($0.count) } ?? 1)
        }
        let next = milestones.first { $0.count > count }
        return Progress(
            achieved: milestones.last { $0.count <= count }, next: next,
            fraction: next.map { Double(count) / Double($0.count) } ?? 0)
    }
}

/// Keep complete sentences and set plurals in the catalog, rather than composing English grammar.
struct DashboardBenchmarkCopy {
    let bundle: Bundle
    let locale: Locale

    init(bundle: Bundle = .main, locale: Locale? = nil) {
        self.bundle = bundle
        self.locale = locale ?? Locale(identifier: bundle.preferredLocalizations.first ?? "en")
    }

    private func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: locale, arguments: arguments)
    }

    func title(_ milestone: DashboardProgressBenchmark.Milestone) -> String {
        guard milestone.title == .fourClassics, milestone.sets > 1 else {
            return localized(milestone.title.rawValue)
        }
        return format(
            "%@ complete sets of the Four Great Classical Novels",
            milestone.sets.formatted(.number.locale(locale)))
    }

    func formattedCount(_ count: Int) -> String {
        let count = max(0, count)
        guard locale.language.languageCode?.identifier == "zh" else {
            return Formatters.formattedCompactNumber(count)
        }
        guard count >= 10_000 else { return count.formatted(.number.locale(locale)) }
        let divisor: Double = count >= 100_000_000 ? 100_000_000 : 10_000
        let suffix = count >= 100_000_000 ? "亿" : "万"
        return (Double(count) / divisor).formatted(
            .number.precision(.fractionLength(0...2)).locale(locale)) + suffix
    }

    func summary(count: Int) -> String {
        let count = max(0, count)
        let progress = DashboardProgressBenchmark.progress(for: count)
        if let achieved = progress.achieved {
            return format(
                "Dictated %@ words / characters — roughly the length of %@.",
                formattedCount(count), title(achieved))
        }
        if count == 1 {
            return localized("Dictated 1 word / character. Your first literary milestone is ahead.")
        }
        return format(
            "Dictated %@ words / characters. Your first literary milestone is ahead.",
            formattedCount(count))
    }

    func nextTarget(count: Int) -> String? {
        let progress = DashboardProgressBenchmark.progress(for: count)
        guard let next = progress.next else { return nil }
        // Do not round an incomplete milestone up to 100%.
        let percent = min(99, Int((progress.fraction * 100).rounded(.down)))
        return format(
            "Next: %@ · %@ complete", title(next),
            (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        )
    }

    func explanation(hasLegacyCounts: Bool) -> String {
        let explanation = localized(
            "Chinese characters count individually; English counts by word. Literary lengths are approximate Chinese-original benchmarks, not translation lengths. Saved time assumes 40 words / characters per minute minus recording time."
        )
        guard hasLegacyCounts else { return explanation }
        return explanation + "\n\n"
            + localized(
                "Some older sessions no longer have retained text. Their original counts are preserved, so totals include estimates."
            )
    }
}
