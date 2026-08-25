import AppKit
import Foundation
import os

struct ModeConfigurationApplication {
    let initialUsageContext: VocabularyUsageContext
    let completion: Task<VocabularyUsageContext, Never>
    let waitsForBrowserURL: Bool
}

struct BrowserURLFailureGuidance: Equatable {
    let message: String
    let shouldOfferAutomationSettings: Bool

    static func make(error: Error, browser: BrowserType) -> Self {
        switch error as? BrowserURLError {
        case .some(.noActiveTab), .some(.noActiveWindow):
            return Self(
                message: String(localized: "Open a tab in \(browser.displayName) and try again."),
                shouldOfferAutomationSettings: false
            )
        case .some(.browserNotRunning):
            return Self(
                message: String(localized: "Keep \(browser.displayName) open and try again."),
                shouldOfferAutomationSettings: false
            )
        case .some(.scriptNotFound):
            return Self(
                message: String(localized: "Website detection is unavailable. Restart VoiceInk and try again."),
                shouldOfferAutomationSettings: false
            )
        case .some(.executionFailed), .some(.executionTimedOut), .none:
            return Self(
                message: String(
                    localized:
                        "Could not read the current website from \(browser.displayName). Allow VoiceInk in System Settings > Privacy & Security > Automation, then try again."
                ),
                shouldOfferAutomationSettings: true
            )
        }
    }

    static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!
}

struct BrowserURLLookupImpact: Equatable {
    let affectsURLMode: Bool
    let affectsWebsiteVocabulary: Bool

    var message: String? {
        switch (affectsURLMode, affectsWebsiteVocabulary) {
        case (true, true):
            return String(localized: "Website-specific mode and vocabulary were not applied.")
        case (true, false):
            return String(localized: "The website-specific mode was not applied.")
        case (false, true):
            return String(localized: "Website vocabulary was not applied.")
        case (false, false):
            return nil
        }
    }
}

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private let browserURLService = BrowserURLService.shared

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.detection"
    )

    private init() {}

    @MainActor
    @discardableResult
    func beginApplyingConfiguration(
        modeId: UUID? = nil,
        target: RecordingContextTarget? = nil,
        resolveVocabularyDomain: Bool = false,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) -> ModeConfigurationApplication {
        if let modeId,
            let config = ModeManager.shared.getConfiguration(with: modeId)
        {
            guard shouldApply() else {
                return immediateApplication(context: .none)
            }
            // Explicit mode selection must not depend on macOS being able to
            // identify the frontmost application.
            ModeManager.shared.setActiveConfiguration(config)
        }

        let frontmostApp = target.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
            ?? NSWorkspace.shared.frontmostApplication
        guard let frontmostApp,
            let bundleIdentifier = target?.activeSurface.bundleIdentifier ?? frontmostApp.bundleIdentifier
        else {
            return immediateApplication(context: .none)
        }

        let usageContext = VocabularyUsageContext(
            bundleIdentifier: bundleIdentifier,
            applicationName: target?.activeSurface.applicationName ?? frontmostApp.localizedName,
            domain: nil
        )

        guard shouldApply() else {
            return immediateApplication(context: usageContext)
        }
        currentApplication = frontmostApp

        if modeId == nil {
            let quickConfig =
                ModeManager.shared.getConfigurationForApp(bundleIdentifier)
                ?? ModeManager.shared.getDefaultConfiguration()
            if let quickConfig {
                ModeManager.shared.setActiveConfiguration(quickConfig)
            }
        }

        guard let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return immediateApplication(context: usageContext)
        }

        let hasURLSpecificConfiguration = ModeManager.shared.configurations.contains { configuration in
            configuration.isEnabled && !configuration.allURLConfigs.isEmpty
        }
        let affectsURLMode = modeId == nil && hasURLSpecificConfiguration
        let shouldResolveBrowserURL = resolveVocabularyDomain || affectsURLMode
        guard shouldResolveBrowserURL else {
            return immediateApplication(context: usageContext)
        }

        let completion = Task { [weak self] in
            guard let self else { return usageContext }

            do {
                let currentURL = try await self.browserURLService.getCurrentURL(from: browserType)
                await MainActor.run {
                    guard modeId == nil,
                        shouldApply(),
                        let config = ModeManager.shared.getConfigurationForURL(currentURL)
                    else {
                        return
                    }
                    ModeManager.shared.setActiveConfiguration(config)
                }
                return VocabularyUsageContext(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: usageContext.applicationName,
                    domain: currentURL
                )
            } catch is CancellationError {
                return usageContext
            } catch {
                self.logger.error(
                    "❌ Failed to get URL from \(browserType.displayName, privacy: .public): \(error, privacy: .public)")
                await MainActor.run {
                    guard shouldApply() else { return }
                    self.showBrowserURLFailure(
                        error,
                        browser: browserType,
                        impact: BrowserURLLookupImpact(
                            affectsURLMode: affectsURLMode,
                            affectsWebsiteVocabulary: resolveVocabularyDomain
                        )
                    )
                }
                return usageContext
            }
        }
        return ModeConfigurationApplication(
            initialUsageContext: usageContext,
            completion: completion,
            waitsForBrowserURL: true
        )
    }

    func applyConfiguration(modeId: UUID? = nil) async {
        let application = await MainActor.run {
            beginApplyingConfiguration(modeId: modeId)
        }
        _ = await application.completion.value
    }

    private func immediateApplication(context: VocabularyUsageContext) -> ModeConfigurationApplication {
        ModeConfigurationApplication(
            initialUsageContext: context,
            completion: Task { context },
            waitsForBrowserURL: false
        )
    }

    @MainActor
    private func showBrowserURLFailure(
        _ error: Error,
        browser: BrowserType,
        impact: BrowserURLLookupImpact
    ) {
        let guidance = BrowserURLFailureGuidance.make(error: error, browser: browser)
        let message = [guidance.message, impact.message]
            .compactMap { $0 }
            .joined(separator: " ")

        let actionButton: (label: String, action: () -> Void)? = if guidance.shouldOfferAutomationSettings {
            (
                String(localized: "Open System Settings"),
                { NSWorkspace.shared.open(BrowserURLFailureGuidance.automationSettingsURL) }
            )
        } else {
            nil
        }
        NotificationManager.shared.showNotification(
            title: message,
            type: .warning,
            duration: 8,
            actionButton: actionButton
        )
    }
}
