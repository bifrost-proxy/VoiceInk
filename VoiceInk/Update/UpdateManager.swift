import AppKit
import Foundation

enum UpdateActivity: Equatable {
    case idle
    case checking
    case downloading(progress: Double?)
    case verifying
    case preparing
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .preparing, .installing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var downloadProgress: Double? {
        guard case .downloading(let progress) = self else { return nil }
        return progress.map { min(max($0, 0), 1) }
    }
}

enum UpdateCheckOutcome: Equatable {
    case updateAvailable(VoiceInkRelease)
    case upToDate
    case failed(String)
}

enum UpdateMenuAction: Equatable {
    case check
    case showProgress
    case install(version: String)
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    nonisolated static let automaticCheckInterval: TimeInterval = 60 * 60
    nonisolated static let automaticallyChecksKey = "AutomaticallyChecksForUpdates"

    @Published private(set) var availableRelease: VoiceInkRelease?
    @Published private(set) var activity: UpdateActivity = .idle
    @Published private(set) var lastCheckMessage: String?

    private var timer: Timer?
    private var hasStarted = false
    private var checkInProgress = false

    var automaticallyChecksForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: Self.automaticallyChecksKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.automaticallyChecksKey)
            configureTimer()
        }
    }

    var isBusy: Bool { activity.isBusy }
    var progressFraction: Double? { activity.downloadProgress }
    var progressPercentage: Int? {
        progressFraction.map { Int(($0 * 100).rounded()) }
    }

    var menuAction: UpdateMenuAction {
        Self.menuAction(activity: activity, availableRelease: availableRelease)
    }

    var showsMenuBarUpdateBadge: Bool {
        availableRelease != nil
    }

    var statusText: String {
        switch activity {
        case .idle:
            return lastCheckMessage ?? String(localized: "Check for Updates")
        case .checking:
            return String(localized: "Checking for Updates…")
        case .downloading:
            return String(localized: "Downloading VoiceInk…")
        case .verifying:
            return String(localized: "Verifying Update…")
        case .preparing:
            return String(localized: "Preparing Update…")
        case .installing:
            return String(localized: "Installing and Restarting…")
        case .failed(let message):
            return message
        }
    }

    private init() {}

    nonisolated static func menuAction(
        activity: UpdateActivity,
        availableRelease: VoiceInkRelease?
    ) -> UpdateMenuAction {
        if activity.isBusy {
            return .showProgress
        }
        if let availableRelease {
            return .install(version: availableRelease.version)
        }
        return .check
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        configureTimer()

        guard automaticallyChecksForUpdates,
            ProcessInfo.processInfo.environment["VOICEINK_SKIP_UPDATE_CHECK"] == nil
        else {
            return
        }
        Task { _ = await checkForUpdates() }
    }

    @discardableResult
    func checkForUpdates() async -> UpdateCheckOutcome {
        guard !checkInProgress, !isInstalling else {
            if let availableRelease { return .updateAvailable(availableRelease) }
            return .failed(String(localized: "An update operation is already in progress."))
        }

        checkInProgress = true
        activity = .checking
        lastCheckMessage = nil
        defer { checkInProgress = false }

        do {
            let release = try await UpdateService.fetchLatestRelease()
            if UpdateService.isNewer(release.version, than: UpdateService.currentVersion) {
                availableRelease = release
                activity = .idle
                return .updateAvailable(release)
            }

            availableRelease = nil
            activity = .idle
            lastCheckMessage = String(localized: "Up to Date")
            return .upToDate
        } catch {
            let message = error.localizedDescription
            activity = .failed(message)
            return .failed(message)
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease, !isInstalling else { return }
        activity = .downloading(progress: 0)
        lastCheckMessage = nil

        Task {
            do {
                let relay = UpdateProgressRelay { [weak self] progress in
                    self?.apply(progress)
                }
                let plan = try await UpdateInstaller.prepare(release: release) { progress in
                    relay.send(progress)
                }
                activity = .installing
                try plan.launch()
                NSApp.terminate(nil)
            } catch {
                activity = .failed(error.localizedDescription)
            }
        }
    }

    private var isInstalling: Bool {
        switch activity {
        case .downloading, .verifying, .preparing, .installing:
            return true
        default:
            return false
        }
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil

        guard hasStarted,
            automaticallyChecksForUpdates,
            ProcessInfo.processInfo.environment["VOICEINK_SKIP_UPDATE_CHECK"] == nil
        else {
            return
        }

        let timer = Timer(timeInterval: Self.automaticCheckInterval, repeats: true) { _ in
            Task { @MainActor in
                _ = await UpdateManager.shared.checkForUpdates()
            }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func apply(_ progress: UpdatePreparationProgress) {
        switch progress {
        case .downloading(let fraction):
            activity = .downloading(progress: fraction)
        case .verifying:
            activity = .verifying
        case .preparing:
            activity = .preparing
        }
    }
}

private final class UpdateProgressRelay: @unchecked Sendable {
    private let handler: @MainActor @Sendable (UpdatePreparationProgress) -> Void

    init(handler: @escaping @MainActor @Sendable (UpdatePreparationProgress) -> Void) {
        self.handler = handler
    }

    func send(_ progress: UpdatePreparationProgress) {
        Task { @MainActor [handler] in handler(progress) }
    }
}
