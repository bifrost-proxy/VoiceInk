import AppKit
import SwiftUI
import XCTest

@testable import VoiceInk

@MainActor
final class DashboardBenchmarkRenderingTests: XCTestCase {
    func testChineseCardLayouts() throws { try renderCards(language: "zh-Hans") }
    func testEnglishCardLayouts() throws { try renderCards(language: "en") }

    private func renderCards(language: String) throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let locale = Locale(identifier: language)
        let copy = DashboardBenchmarkCopy(bundle: bundle, locale: locale)
        for count in [0, 82_200, 2_220_000, 6_140_000] {
            let card = DashboardHeroCard(
                localizationBundle: bundle,
                headline: .savedTime("24h 27m"),
                subtext: copy.summary(count: count),
                benchmarkProgress: copy.nextTarget(count: count),
                benchmarkHelp: copy.explanation(hasLegacyCounts: true),
                actionTitle: "View Insights", actionIcon: "chart.line.uptrend.xyaxis",
                actionHelp: "", actionAccessibilityLabel: "View insights", onViewInsights: {}
            )
            .frame(width: 640)
            .environment(\.locale, locale)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThanOrEqual(image.size.height, 160)
            XCTAssertLessThan(
                image.size.height, 400, "Long titles should wrap within a practical card height")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Literary-\(language)-\(count)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-literary-\(language)-\(count).png")
            try png.write(to: output)
            print("Literary card render: \(output.path)")
        }
    }
}
