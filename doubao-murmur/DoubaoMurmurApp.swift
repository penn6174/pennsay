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
        let scheduler = AutoUpdateScheduler(settingsStore: settingsStore, updater: .shared)
        scheduler.start()
        autoUpdateScheduler = scheduler
    }

    private func observeState() {
        appState.$loginStatus
            .combineLatest(appState.$recordingState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusButton()
                self?.rebuildMenu()
                guard let self else { return }
                AutomationController.writeState(
                    appState: self.appState,
                    overlay: self.overlayPanel.currentSnapshot(),
                    settingsStore: self.settingsStore
                )
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        switch appState.recordingState {
        case .recording, .starting:
            symbolName = "mic.fill"
        case .stopping, .refining:
            symbolName = "waveform"
        case .idle:
            symbolName = "waveform"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: AppEnvironment.displayName)
        button.toolTip = AppEnvironment.displayName
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

        let supportItem = NSMenuItem(title: "联系支持并附带日志...", action: #selector(contactSupport), keyEquivalent: "")
        menu.addItem(supportItem)

        let updateItem = NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "u")
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
        alert.informativeText = "Version \(version) (\(build))\n\(AppEnvironment.madeByLine)\nSupport: \(AppEnvironment.supportEmail)"
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

    @objc private func contactSupport() {
        sendSupportEmail(reason: "用户手动反馈")
    }

    private func promptToSendDiagnosticsAfterUnexpectedExit() {
        let alert = NSAlert()
        alert.messageText = "检测到上次未正常退出"
        alert.informativeText = "\(AppEnvironment.displayName) 上次可能发生了崩溃、卡死或被强制退出。现在可以把本地日志打包进邮件草稿，发送到 \(AppEnvironment.supportEmail) 以便排查。"
        alert.addButton(withTitle: "生成邮件")
        alert.addButton(withTitle: "打开日志文件夹")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            sendSupportEmail(reason: "异常退出后重启")
        case .alertSecondButtonReturn:
            openLogsFolder()
        default:
            break
        }
    }

    private func sendSupportEmail(reason: String) {
        do {
            try diagnosticsManager.composeSupportEmail(reason: reason)
        } catch {
            log.error("support email compose failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "无法生成诊断邮件"
            alert.informativeText = "\(error.localizedDescription)\n\n你也可以手动把日志目录里的文件发送到 \(AppEnvironment.supportEmail)。"
            alert.addButton(withTitle: "打开日志文件夹")
            alert.addButton(withTitle: "好的")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openLogsFolder()
            }
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
                    let alert = NSAlert()
                    alert.messageText = "检查更新"
                    alert.informativeText = "已是最新 v\(currentVersion)"
                    alert.addButton(withTitle: "好的")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                case .updateAvailable(let release):
                    // 优先走应用内自动下载 + 退出时替换路径；仅在 /Applications
                    // 不可写等情况下 fallback 到打开 Release 页面
                    let updater = AppUpdater.shared
                    let canSilent = updater.canPrepareSilently(for: release)
                    let alert = NSAlert()
                    alert.messageText = "发现新版本 v\(release.version)"
                    if canSilent {
                        alert.informativeText = (release.releaseNotes.isEmpty
                            ? "下载后 Cmd+Q 退出 \(AppEnvironment.displayName)，重新打开即为新版本。"
                            : release.releaseNotes + "\n\n下载后 Cmd+Q 退出 \(AppEnvironment.displayName)，重新打开即为新版本。")
                        alert.addButton(withTitle: "下载并准备")
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
                                body = "\(AppEnvironment.displayName) 新版已下载好，Cmd+Q 退出后重新打开生效"
                            case .alreadyPrepared:
                                body = "新版本已在待安装队列，Cmd+Q 退出后重新打开生效"
                            }
                            NotificationHelper.show(title: AppEnvironment.displayName, body: body)
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
}
