import AVFoundation
import Combine
import SwiftUI

@main
struct PennSayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = AppLog(category: "AppDelegate")

    private var statusItem: NSStatusItem!
    private let updateBadgeView = StatusBadgeView()
    private let appState = AppState.shared
    private let settingsStore = SettingsStore.shared
    private let diagnosticsManager = SupportDiagnosticsManager.shared
    private var autoUpdateScheduler: AutoUpdateScheduler?
    private var webViewManager: WebViewManager!
    private var hotkeyManager: HotkeyManager!
    private var transcriptionManager: TranscriptionManager!
    private var overlayPanel: OverlayPanel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogStore.bootstrap()
        let previousLaunchEndedUnexpectedly = diagnosticsManager.beginSession()
        log.notice("application did finish launching")
        setupStatusItem()
        setupOverlay()
        setupWebView()
        setupHotkey()
        setupTranscription()
        setupAutoUpdateScheduler()
        observeState()
        applyAutomationLaunchState()

        // Onboarding prompt for launch-at-login is deliberately triggered by
        // the first successful paste (after Accessibility + Microphone system
        // prompts), NOT at launch — avoids stacking three native dialogs.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFirstPasteCompletion),
            name: Notification.Name("PennSayDidCompletePaste"),
            object: nil
        )

        if previousLaunchEndedUnexpectedly && !AutomationController.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.promptToSendDiagnosticsAfterUnexpectedExit()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticsManager.markCleanExit()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateStatusButton()
        rebuildMenu()
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel(appState: appState)
    }

    private func setupWebView() {
        webViewManager = WebViewManager(appState: appState)
        webViewManager.onLoginStatusChange = { [weak self] status, _ in
            Task { @MainActor in
                guard let self else { return }
                if status == "loggedIn" {
                    self.appState.loginStatus = .loggedIn
                    self.extractSaveAndDestroyWebView()
                } else {
                    self.appState.loginStatus = .notLoggedIn
                }
            }
        }

        if let mockLoginStatus = AutomationController.mockLoginStatus {
            appState.loginStatus = mockLoginStatus
            return
        }

        if ASRParamsStore.hasSavedParams {
            appState.loginStatus = .loggedIn
        } else {
            appState.loginStatus = .notLoggedIn
            webViewManager.load()
            webViewManager.showLoginWindow()
        }
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager(configuration: settingsStore.shortcutConfiguration)
    }

    private func setupTranscription() {
        transcriptionManager = TranscriptionManager(
            appState: appState,
            webViewManager: webViewManager,
            overlayPanel: overlayPanel,
            hotkeyManager: hotkeyManager,
            settingsStore: settingsStore
        )
        transcriptionManager.onAuthExpired = { [weak self] in
            self?.promptForReLogin()
        }
        transcriptionManager.start()
    }

    private func setupAutoUpdateScheduler() {
        let scheduler = AutoUpdateScheduler(
            settingsStore: settingsStore,
            updater: .shared,
            appState: appState
        )
        scheduler.start()
        autoUpdateScheduler = scheduler
    }

    private func observeState() {
        appState.$loginStatus
            .combineLatest(appState.$recordingState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshStatusUI()
            }
            .store(in: &cancellables)

        appState.$availableUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusUI()
            }
            .store(in: &cancellables)

        // Voice-use → update check (debounced to 30 min inside the scheduler).
        // We trigger on transition into .starting so every recording session
        // — Hold, single tap, double tap — counts as one "voice use" event.
        appState.$recordingState
            .removeDuplicates()
            .filter { $0 == .starting }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.autoUpdateScheduler?.checkOnVoiceUse()
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        switch appState.recordingState {
        case .recording, .starting:
            // Active recording — use the colorful mic SF Symbol so the
            // menu bar reflects "currently capturing" at a glance.
            button.title = ""
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: AppEnvironment.displayName)
        case .stopping, .refining:
            button.title = ""
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: AppEnvironment.displayName)
        case .idle:
            // Idle default — the ninja emoji is the Penn-identity icon
            // (renders in color automatically on macOS 11+).
            button.image = nil
            button.title = "🥷"
        }
        button.toolTip = AppEnvironment.displayName
        configureStatusBadge(on: button)
        updateBadgeView.count = appState.availableUpdateBadgeCount
    }

    private func configureStatusBadge(on button: NSStatusBarButton) {
        guard updateBadgeView.superview == nil else { return }
        updateBadgeView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(updateBadgeView)
        NSLayoutConstraint.activate([
            updateBadgeView.widthAnchor.constraint(equalToConstant: 14),
            updateBadgeView.heightAnchor.constraint(equalToConstant: 14),
            updateBadgeView.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            updateBadgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1)
        ])
    }

    private func refreshStatusUI() {
        updateStatusButton()
        rebuildMenu()
        AutomationController.writeState(
            appState: appState,
            overlay: overlayPanel.currentSnapshot(),
            settingsStore: settingsStore
        )
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let statusItem = NSMenuItem(title: "状态: \(appState.loginStatus.rawValue)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem(title: "关于 \(AppEnvironment.displayName)", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())

        if appState.loginStatus != .loggedIn {
            menu.addItem(NSMenuItem(title: "登录豆包", action: #selector(showLogin), keyEquivalent: "l"))
        }

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)

        let logsItem = NSMenuItem(title: "打开日志文件夹", action: #selector(openLogsFolder), keyEquivalent: "")
        menu.addItem(logsItem)

        // If a silent download has already staged a new release, the user
        // should be able to apply it with a single click without re-hitting
        // the GitHub API. Fall back to the regular "检查更新" flow otherwise.
        let updateItem: NSMenuItem
        if let release = appState.availableUpdate, AppUpdater.shared.isPrepared(for: release) {
            updateItem = NSMenuItem(
                title: "立即更新到 v\(release.version)",
                action: #selector(applyPreparedUpdate),
                keyEquivalent: "u"
            )
            updateItem.image = Self.makeMenuBadgeImage(count: appState.availableUpdateBadgeCount)
        } else {
            updateItem = NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "u")
            if appState.hasAvailableUpdate {
                updateItem.image = Self.makeMenuBadgeImage(count: appState.availableUpdateBadgeCount)
            }
        }
        menu.addItem(updateItem)

        let uninstallItem = NSMenuItem(title: "卸载并退出", action: #selector(uninstallAndQuit), keyEquivalent: "")
        menu.addItem(uninstallItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
    }

    private func extractSaveAndDestroyWebView() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            if let params = await webViewManager.extractASRParams() {
                ASRParamsStore.save(params)
                appState.loginStatus = .loggedIn
            } else {
                appState.loginStatus = .notLoggedIn
            }
            webViewManager.hideLoginWindow()
            webViewManager.destroyWebView()
        }
    }

    private func promptForReLogin() {
        let alert = NSAlert()
        alert.messageText = "认证已过期"
        alert.informativeText = "豆包登录凭证已失效，需要重新登录。"
        alert.addButton(withTitle: "重新登录")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            webViewManager.load()
            webViewManager.showLoginWindow()
        }
    }

    private func requestMicrophonePermission() {
        guard !AutomationController.isEnabled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                LogStore.write("[permission] microphone granted=\(granted)")
            }
        case .denied, .restricted:
            log.error("microphone permission denied")
        @unknown default:
            break
        }
    }

    private func applyAutomationLaunchState() {
        guard AutomationController.isEnabled else { return }
        if let draft = AutomationController.llmOverrideDraft {
            try? settingsStore.saveLLMConfiguration(from: draft)
        }

        if AutomationController.resetPromptOnLaunch {
            settingsStore.resetSystemPrompt()
        }

        AutomationController.writeState(
            appState: appState,
            overlay: overlayPanel.currentSnapshot(),
            settingsStore: settingsStore
        )

        if AutomationController.openSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showSettings()
            }
        }

        if AutomationController.simulateAuthExpiredOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.appState.loginStatus = .notLoggedIn
                self.promptForReLogin()
            }
        }

        if let shortcutOverride = AutomationController.shortcutOverride {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.settingsStore.updateShortcut(shortcutOverride)
            }
        }

        if AutomationController.showCapsLockGuideOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.showCapsLockGuideAlert()
            }
        }

        if AutomationController.checkUpdateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.checkForUpdates()
            }
        }

        if AutomationController.autoRecordOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.transcriptionManager.automationStartRecording()
            }
            if let stopAfterMs = AutomationController.autoStopAfterMilliseconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stopAfterMs)) {
                    self.transcriptionManager.automationStopRecording()
                }
            }
        }

        if AutomationController.autoUninstallOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                try? UninstallManager.uninstallAndQuit()
            }
        }

        AutomationController.writeState(
            appState: appState,
            overlay: overlayPanel.currentSnapshot(),
            settingsStore: settingsStore
        )
    }

    @objc private func showLogin() {
        webViewManager.showLoginWindow()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.showWindowAndActivate()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        alert.messageText = AppEnvironment.displayName
        alert.informativeText = "Version \(version) (\(build))\n\(AppEnvironment.madeByLine)"
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showCapsLockGuideAlert() {
        let alert = NSAlert()
        alert.messageText = "Caps Lock 需要先关闭大小写锁定行为"
        alert.informativeText = "请前往 系统设置 -> 键盘 -> 修饰键，将 Caps Lock 改成无操作或其他行为后再使用它作为触发键。"
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openLogsFolder() {
        NSWorkspace.shared.open(AppEnvironment.ensureLogsDirectoryExists())
    }

    private func promptToSendDiagnosticsAfterUnexpectedExit() {
        let alert = NSAlert()
        alert.messageText = "检测到上次未正常退出"
        alert.informativeText = "\(AppEnvironment.displayName) 上次可能发生了崩溃、卡死或被强制退出。你可以先查看本地日志目录，必要时再自行处理诊断文件。"
        alert.addButton(withTitle: "打开日志文件夹")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openLogsFolder()
        default:
            break
        }
    }

    @objc private func handleFirstPasteCompletion() {
        let key = "onboarding.launchAtLoginPrompted"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        // If user already enabled launch-at-login in Settings, mark prompt as
        // seen and skip the dialog.
        guard !settingsStore.launchAtLoginEnabled else {
            defaults.set(true, forKey: key)
            return
        }
        defaults.set(true, forKey: key)

        // Delay so the overlay退场 animation finishes and the paste lands in
        // the target app before we steal focus with an alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "让 \(AppEnvironment.displayName) 开机自启？"
            alert.informativeText = "\(AppEnvironment.displayName) 是后台工具——定时检查更新、快捷键监听、自动升级都依赖它常驻。开机自启是最推荐的设置，随时可在 设置 → General 里关闭。"
            alert.addButton(withTitle: "开启")
            alert.addButton(withTitle: "以后再说")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try self.settingsStore.setLaunchAtLoginEnabled(true)
            } catch {
                self.log.error("launch at login onboarding failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func checkForUpdates() {
        Task {
            do {
                let result = try await UpdateChecker.checkLatest()
                switch result {
                case .upToDate(let currentVersion):
                    appState.availableUpdate = nil
                    let alert = NSAlert()
                    alert.messageText = "检查更新"
                    alert.informativeText = "已是最新 v\(currentVersion)"
                    alert.addButton(withTitle: "好的")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                case .updateAvailable(let release):
                    appState.availableUpdate = release
                    // 优先走应用内自动下载 + 退出时替换路径；仅在 /Applications
                    // 不可写等情况下 fallback 到打开 Release 页面
                    let updater = AppUpdater.shared
                    let canSilent = updater.canPrepareSilently(for: release)
                    let alert = NSAlert()
                    alert.messageText = "发现新版本 v\(release.version)"
                    if canSilent {
                        alert.informativeText = (release.releaseNotes.isEmpty
                            ? "现在下载后会自动退出并重新打开 \(AppEnvironment.displayName)。自动检查更新仍保持“只准备、不打断工作”的旧策略。"
                            : release.releaseNotes + "\n\n现在下载后会自动退出并重新打开 \(AppEnvironment.displayName)。自动检查更新仍保持“只准备、不打断工作”的旧策略。")
                        alert.addButton(withTitle: "下载并立即重启")
                        alert.addButton(withTitle: "稍后")
                    } else {
                        alert.informativeText = release.releaseNotes.isEmpty
                            ? "当前安装位置不可写，需要在浏览器中手动下载。"
                            : release.releaseNotes
                        alert.addButton(withTitle: "打开 Release")
                        alert.addButton(withTitle: "取消")
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { break }
                    if canSilent {
                        do {
                            let result = try await updater.prepareUpdateIfNeeded(release: release)
                            let body: String
                            switch result {
                            case .prepared:
                                body = "\(AppEnvironment.displayName) 新版已下载好，正在自动重启完成更新"
                            case .alreadyPrepared:
                                body = "新版本已在待安装队列，正在自动重启完成更新"
                            }
                            NotificationHelper.show(title: AppEnvironment.displayName, body: body)
                            try updater.scheduleRelaunchAfterTermination()
                            appState.availableUpdate = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                NSApp.terminate(nil)
                            }
                        } catch {
                            log.error("manual update preparation failed: \(error.localizedDescription)")
                            let failAlert = NSAlert()
                            failAlert.messageText = "自动下载失败"
                            failAlert.informativeText = "\(error.localizedDescription)\n将打开 Release 页面让你手动下载。"
                            failAlert.addButton(withTitle: "打开 Release")
                            failAlert.addButton(withTitle: "取消")
                            if failAlert.runModal() == .alertFirstButtonReturn {
                                AppUpdater.openReleasePage(release.htmlURL)
                            }
                        }
                    } else {
                        AppUpdater.openReleasePage(release.htmlURL)
                    }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "检查更新失败"
                alert.informativeText = "\(error.localizedDescription)\n备用链接: https://github.com/\(AppEnvironment.githubRepoOwner)/\(AppEnvironment.githubRepoName)/releases"
                alert.addButton(withTitle: "好的")
                alert.addButton(withTitle: "打开备用链接")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                if response == .alertSecondButtonReturn,
                   let url = URL(string: "https://github.com/\(AppEnvironment.githubRepoOwner)/\(AppEnvironment.githubRepoName)/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// One-click apply for an already-downloaded update. Assumes the
    /// prepared identifier matches `appState.availableUpdate`; the menu
    /// only wires this when `AppUpdater.isPrepared(for:)` is true.
    @objc private func applyPreparedUpdate() {
        guard let release = appState.availableUpdate else { return }
        let updater = AppUpdater.shared
        do {
            try updater.scheduleRelaunchAfterTermination()
            appState.availableUpdate = nil
            log.notice("applying prepared update v\(release.version)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            log.error("apply prepared update failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "立即更新失败"
            alert.informativeText = "\(error.localizedDescription)\n请从 菜单 → 检查更新 手动重试。"
            alert.addButton(withTitle: "好的")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func uninstallAndQuit() {
        let alert = NSAlert()
        alert.messageText = "将删除应用 配置 日志 登录凭证"
        alert.informativeText = "不可恢复。继续？"
        alert.addButton(withTitle: "卸载并退出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try UninstallManager.uninstallAndQuit()
        } catch {
            let failedAlert = NSAlert()
            failedAlert.messageText = "卸载失败"
            failedAlert.informativeText = error.localizedDescription
            failedAlert.addButton(withTitle: "好的")
            failedAlert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private static func makeMenuBadgeImage(count: Int) -> NSImage? {
        guard count > 0 else { return nil }
        let text = "\(count)"
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .paragraphStyle: paragraph
        ]
        let rect = NSRect(x: 0, y: 1, width: size.width, height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attributes)
        image.unlockFocus()
        return image
    }
}

private final class StatusBadgeView: NSView {
    private let textField = NSTextField(labelWithString: "")

    var count: Int = 0 {
        didSet {
            isHidden = count <= 0
            textField.stringValue = "\(count)"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = 7
        isHidden = true

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.alignment = .center
        textField.textColor = .white
        textField.font = .systemFont(ofSize: 9, weight: .bold)
        addSubview(textField)

        NSLayoutConstraint.activate([
            textField.centerXAnchor.constraint(equalTo: centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}
