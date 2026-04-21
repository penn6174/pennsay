import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let rootView = SettingsRootView(store: .shared)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(AppEnvironment.displayName) Settings"
        window.setContentSize(NSSize(width: 700, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func showWindowAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettingsView(store: store)
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
            LLMSettingsView(store: store)
                .tabItem { Label("LLM 润色", systemImage: "sparkles") }
        }
        .padding(20)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLoginError = ""
    @State private var showLaunchAtLoginError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Status") {
                    LabeledContent("登录状态", value: AppState.shared.loginStatus.rawValue)
                    LabeledContent("快捷键", value: store.shortcutConfiguration.triggerKey.displayName)
                    LabeledContent("模式", value: store.shortcutConfiguration.mode.displayName)
                }

                Section("Startup") {
                    Toggle(
                        "自动检查更新",
                        isOn: Binding(
                            get: { store.autoCheckUpdatesEnabled },
                            set: { store.setAutoCheckUpdatesEnabled($0) }
                        )
                    )
                    Toggle(
                        "登录时启动 \(AppEnvironment.displayName)",
                        isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { newValue in
                                do {
                                    try store.setLaunchAtLoginEnabled(newValue)
                                } catch {
                                    launchAtLoginError = error.localizedDescription
                                    showLaunchAtLoginError = true
                                }
                            }
                        )
                    )
                }

                Section("Logs") {
                    Text(AppEnvironment.logsDirectoryURL.path)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    Button("打开日志文件夹") {
                        NSWorkspace.shared.open(AppEnvironment.ensureLogsDirectoryExists())
                    }
                }

                Section("Version") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")
                }
            }
            .formStyle(.grouped)

            Text(AppEnvironment.madeByLine)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("登录时启动设置失败", isPresented: $showLaunchAtLoginError) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(launchAtLoginError)
        }
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject var store: SettingsStore

    @State private var triggerKey: ShortcutTriggerKey = .rightOption
    @State private var mode: ShortcutMode = .hold
    @State private var doubleTapWindowMs: Double = Double(ShortcutConfiguration.defaultDoubleTapWindowMs)

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("触发键", selection: $triggerKey) {
                    ForEach(ShortcutTriggerKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: triggerKey) { _, newValue in
                    if newValue == .capsLock {
                        presentCapsLockGuide()
                    }
                }

                Picker("触发模式", selection: $mode) {
                    ForEach(ShortcutMode.allCases) { currentMode in
                        Text(currentMode.displayName).tag(currentMode)
                    }
                }

                HStack {
                    Text("Double Tap 时间窗")
                    Slider(
                        value: $doubleTapWindowMs,
                        in: Double(ShortcutConfiguration.minimumDoubleTapWindowMs)...Double(ShortcutConfiguration.maximumDoubleTapWindowMs),
                        step: 10
                    )
                    Text("\(Int(doubleTapWindowMs))ms")
                        .frame(width: 70, alignment: .trailing)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .disabled(mode != .doubleTapToggle)

                if triggerKey == .function {
                    Text("Fn 在很多键盘布局里容易与系统行为冲突，不建议作为默认触发键。")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Save") {
                    store.updateShortcut(
                        ShortcutConfiguration(
                            triggerKey: triggerKey,
                            mode: mode,
                            doubleTapWindowMs: Int(doubleTapWindowMs)
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadFromStore()
        }
    }

    private func loadFromStore() {
        triggerKey = store.shortcutConfiguration.triggerKey
        mode = store.shortcutConfiguration.mode
        doubleTapWindowMs = Double(store.shortcutConfiguration.doubleTapWindowMs)
    }

    private func presentCapsLockGuide() {
        let alert = NSAlert()
        alert.messageText = "Caps Lock 需要先关闭大小写锁定行为"
        alert.informativeText = "请前往 系统设置 → 键盘 → 修饰键，将 Caps Lock 改成无操作或其他行为后再使用它作为触发键。"
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

private struct LLMSettingsView: View {
    @ObservedObject var store: SettingsStore

    @State private var draft = LLMSettingsDraft(configuration: .default, apiKey: "")
    @State private var statusMessage = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("启用 LLM 润色", isOn: $draft.isEnabled)
                    .disabled(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                TextField("API Base URL", text: $draft.apiBaseURL)
                SecureField("API Key", text: $draft.apiKey)
                TextField("Model", text: $draft.model)
                Stepper(value: $draft.timeoutSeconds, in: 1...60) {
                    Text("Timeout \(draft.timeoutSeconds)s")
                }
            }

            Section("System Prompt") {
                TextEditor(text: $draft.systemPrompt)
                    .font(.system(size: 13, weight: .regular))
                    .frame(minHeight: 220)
                HStack {
                    Button("重置 System Prompt 为默认值") {
                        draft.systemPrompt = LLMConfiguration.defaultPrompt
                    }
                    Spacer()
                    Button(isTesting ? "Testing…" : "Test") {
                        testConfiguration()
                    }
                    .disabled(isTesting)
                    Button("Save") {
                        save()
                    }
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draft = store.llmDraft()
        }
    }

    private func save() {
        do {
            try store.saveLLMConfiguration(from: draft)
            draft = store.llmDraft()
            statusMessage = "已保存"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testConfiguration() {
        isTesting = true
        statusMessage = ""
        Task {
            defer { isTesting = false }
            do {
                try await LLMRefiner().validate(
                    configuration: LLMConfiguration(
                        isEnabled: draft.isEnabled,
                        apiBaseURL: draft.apiBaseURL,
                        model: draft.model,
                        systemPrompt: draft.systemPrompt,
                        timeoutSeconds: draft.timeoutSeconds
                    ),
                    apiKey: draft.apiKey
                )
                statusMessage = "连接成功"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
