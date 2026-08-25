import AppKit
import Foundation
import os

struct ModeConfigurationApplication {
    let initialUsageContext: VocabularyUsageContext
    let completion: Task<VocabularyUsageContext, Never>
    let waitsForBrowserURL: Bool
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

        if let modeId,
            let config = ModeManager.shared.getConfiguration(with: modeId)
        {
            ModeManager.shared.setActiveConfiguration(config)
        } else {
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
        let shouldResolveBrowserURL = resolveVocabularyDomain || (modeId == nil && hasURLSpecificConfiguration)
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
}
