import AppKit
import Combine
import Foundation

/// Drives automatic update checks at two moments:
///
/// - **Startup** — once, 5 seconds after launch. Covers the case where the
///   user opens the app but hasn't triggered voice input yet.
/// - **Voice use** — called by `TranscriptionManager` every time a
///   recording session starts. The scheduler debounces to at most one
///   network call per `voiceCheckDebounce` (default 30 min) so rapid-fire
///   recordings don't hammer the GitHub API.
///
/// Red-dot badge policy (changed in v1.0.6): `appState.availableUpdate` is
/// set **after** the background download finishes, not when the new release
/// is first detected. This guarantees every visible dot corresponds to a
/// one-click-installable update. Silent-download failures are logged and
/// swallowed so the UI only reflects actionable state.
@MainActor
final class AutoUpdateScheduler {
    private let log = AppLog(category: "AutoUpdateScheduler")
    private let settingsStore: SettingsStore
    private let updater: AppUpdater
    private let appState: AppState
    private let defaults: UserDefaults

    private var startupWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var isChecking = false
    private var lastCheckedAt: Date?

    /// Minimum interval between voice-triggered checks. Short enough that a
    /// long recording session won't leave the user stuck on an old build for
    /// the whole day, long enough that back-to-back taps don't each hit
    /// GitHub.
    private let voiceCheckDebounce: TimeInterval = 30 * 60

    init(
        settingsStore: SettingsStore,
        updater: AppUpdater,
        appState: AppState,
        defaults: UserDefaults = .standard
    ) {
        self.settingsStore = settingsStore
        self.updater = updater
        self.appState = appState
        self.defaults = defaults
    }

    deinit {
        startupWorkItem?.cancel()
    }

    func start() {
        settingsStore.$autoCheckUpdatesEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.log.notice("automatic update checks enabled")
                    self.scheduleStartupCheckIfNeeded()
                } else {
                    self.log.notice("automatic update checks disabled")
                    self.startupWorkItem?.cancel()
                    self.startupWorkItem = nil
                }
            }
            .store(in: &cancellables)

        scheduleStartupCheckIfNeeded()
    }

    /// Called by `TranscriptionManager` when a recording session begins.
    /// Internally debounced — network check only runs when the last check
    /// is more than `voiceCheckDebounce` ago.
    func checkOnVoiceUse() {
        guard settingsStore.autoCheckUpdatesEnabled else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < voiceCheckDebounce {
            return
        }
        Task { [weak self] in
            await self?.performCheck(reason: "voice-use")
        }
    }

    private func scheduleStartupCheckIfNeeded() {
        startupWorkItem?.cancel()
        guard settingsStore.autoCheckUpdatesEnabled else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.performCheck(reason: "startup")
            }
        }
        startupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func performCheck(reason: String) async {
        guard settingsStore.autoCheckUpdatesEnabled else { return }
        guard !isChecking else {
            log.info("skipping \(reason) update check because another check is in progress")
            return
        }

        isChecking = true
        defer {
            isChecking = false
            lastCheckedAt = Date()
        }

        do {
            let result = try await UpdateChecker.checkLatest()
            switch result {
            case .upToDate:
                // Only clear the badge when we know the current build is
                // current. Never clear on error — that would drop legitimate
                // prepared-update state on a transient network blip.
                if appState.availableUpdate != nil {
                    appState.availableUpdate = nil
                }
                log.info("automatic update check (\(reason)) found no newer release")

            case let .updateAvailable(release):
                log.notice("automatic update check (\(reason)) found v\(release.version)")

                // If this release is already staged from a previous check,
                // the badge should already be up; just make sure.
                if updater.isPrepared(for: release) {
                    appState.availableUpdate = release
                    return
                }

                // Can't stage silently (e.g. /Applications not writable) →
                // fall back to old behavior: surface badge + notify, user
                // handles manually via the menu.
                guard updater.canPrepareSilently(for: release) else {
                    appState.availableUpdate = release
                    NotificationHelper.show(
                        title: AppEnvironment.displayName,
                        body: "发现新版本 v\(release.version)，点击菜单栏打开更新"
                    )
                    return
                }

                // Background download. Badge appears only after this
                // completes — Penn 在 v1.0.6 明确要求"红点和提醒都要在下载完以后"。
                do {
                    let preparation = try await updater.prepareUpdateIfNeeded(release: release)
                    appState.availableUpdate = release
                    let body: String
                    switch preparation {
                    case .prepared:
                        body = "v\(release.version) 已下载就绪，点击菜单栏立即更新"
                    case .alreadyPrepared:
                        body = "v\(release.version) 已在待安装队列，点击菜单栏立即更新"
                    }
                    NotificationHelper.show(title: AppEnvironment.displayName, body: body)
                } catch {
                    log.error("silent update preparation failed: \(error.localizedDescription)")
                    // Download failed — don't surface a badge, since the
                    // user can't one-click install yet. They can still hit
                    // "检查更新" in the menu for a manual retry with UI.
                }
            }
        } catch {
            log.error("automatic update check (\(reason)) failed: \(error.localizedDescription)")
        }
    }
}
