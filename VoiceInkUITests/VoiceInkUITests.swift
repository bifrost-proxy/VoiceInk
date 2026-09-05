//
//  VoiceInkUITests.swift
//  VoiceInkUITests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import XCTest

final class VoiceInkUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testChineseBenchmarkExplanation() throws {
        try verifyBenchmarkExplanation(language: "zh-Hans", label: "关于这项估算", text: "汉字逐字计数")
    }

    @MainActor
    func testEnglishBenchmarkExplanation() throws {
        try verifyBenchmarkExplanation(language: "en", label: "About this estimate", text: "Chinese characters count individually")
    }

    @MainActor
    private func verifyBenchmarkExplanation(language: String, label: String, text: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboardingV2", "YES", "-AppLanguagePreference", language,
            "-IsMenuBarOnly", "NO", "-AppleLanguages", "(\(language))"]
        app.launchEnvironment["VOICEINK_SKIP_UPDATE_CHECK"] = "1"
        app.launch()
        defer { app.terminate() }
        app.activate()
        // The recorder can open a permission guidance panel before the main window.
        // Close the guidance without requesting or changing microphone permissions.
        let closeGuidance = app.dialogs.buttons["xmark"].firstMatch
        if closeGuidance.waitForExistence(timeout: 3) { closeGuidance.click() }
        app.menuBars.menuBarItems[language == "zh-Hans" ? "窗口" : "Window"].click()
        app.menuItems["VoiceInk"].firstMatch.click()
        let overview = app.staticTexts[language == "zh-Hans" ? "概览" : "Overview"].firstMatch
        if overview.waitForExistence(timeout: 3) { overview.click() }
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "The dashboard must expose its localized counting explanation")
        button.click()
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Benchmark-explanation-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
