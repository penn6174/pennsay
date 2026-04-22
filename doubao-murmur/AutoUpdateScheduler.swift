import AppKit
import Combine
import Foundation

@MainActor
final class AutoUpdateScheduler {
    private enum Keys {
        static let lastNotifiedTag = "updater.lastAutoNotifiedTag"
    }

    private let log = AppLog(category: "AutoUpdateScheduler")
    private let settingsStore: SettingsStore
    private let updater: AppUpdater
    private let appState: AppState
    private let defaults: UserDefaults
    private let timerQueue = DispatchQueue(label: "pennsay.auto-update-scheduler", qos: .utility)

    private var dailyTimer: DispatchSourceTimer?
    private var startupWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var isChecking = false

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
        dailyTimer?.cancel()
        startupWorkItem?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start() {
        settingsStore.$autoCheckUpdatesEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.log.notice("automatic update checks enabled")
                    self.scheduleStartupCheckIfNeeded()
                    self.rescheduleDailyCheck()
                } else {
                    self.log.notice("automatic update checks disabled")
                    self.dailyTimer?.cancel()
                    self.dailyTimer = nil
                    self.startupWorkItem?.cancel()
                    self.startupWorkItem = nil
                }
            }
            .store(in: &cancellables)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.log.notice("received wake notification, recalibrating update timer")
                self.rescheduleDailyCheck()
            }
        }

        scheduleStartupCheckIfNeeded()
        rescheduleDailyCheck()
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

    private func rescheduleDailyCheck() {
        dailyTimer?.cancel()
        dailyTimer = nil

        guard settingsStore.autoCheckUpdatesEnabled else { return }

        let nextFireDate = nextScheduledDate(from: Date())
        let delay = max(nextFireDate.timeIntervalSinceNow, 1)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + delay, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.performCheck(reason: "daily")
                self.rescheduleDailyCheck()
            }
        }
        timer.resume()
        dailyTimer = timer
        log.notice("next automatic update check scheduled for \(nextFireDate)")
    }

    private func nextScheduledDate(from now: Date) -> Date {
        let calendar = Calendar.current
        let scheduledTime = DateComponents(hour: 3, minute: 30)
        let todayCandidate = calendar.nextDate(
            after: now.addingTimeInterval(-1),
            matching: scheduledTime,
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? now.addingTimeInterval(24 * 60 * 60)

        if todayCandidate > now {
            return todayCandidate
        }

        return calendar.nextDate(
            after: now.addingTimeInterval(24 * 60 * 60),
            matching: scheduledTime,
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    private func performCheck(reason: String) async {
        guard settingsStore.autoCheckUpdatesEnabled else { return }
        guard !isChecking else {
            log.info("skipping \(reason) update check because another check is in progress")
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let result = try await UpdateChecker.checkLatest()
            switch result {
            case .upToDate:
                appState.availableUpdate = nil
                log.info("automatic update check (\(reason)) found no newer release")
            case let .updateAvailable(release):
                appState.availableUpdate = release
                log.notice("automatic update check (\(reason)) found v\(release.version)")
                if updater.canPrepareSilently(for: release) {
                    let preparationResult = try await updater.prepareUpdateIfNeeded(release: release)
                    if preparationResult == .prepared {
                        defaults.set(release.tag, forKey: Keys.lastNotifiedTag)
                        NotificationHelper.show(
                            title: AppEnvironment.displayName,
                            body: "\(AppEnvironment.displayName) 新版已就绪，重启应用生效"
                        )
                    }
                } else if defaults.string(forKey: Keys.lastNotifiedTag) != release.tag {
                    defaults.set(release.tag, forKey: Keys.lastNotifiedTag)
                    NotificationHelper.show(
                        title: AppEnvironment.displayName,
                        body: "发现新版本 v\(release.version)"
                    )
                }
            }
        } catch {
            log.error("automatic update check (\(reason)) failed: \(error.localizedDescription)")
        }
    }
}
