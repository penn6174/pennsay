import Foundation

enum AutomationController {
    struct State: Codable {
        struct ShortcutState: Codable {
            var triggerKey: String
            var mode: String
            var secondaryTriggerKey: String
            var secondaryMode: String
            var doubleTapWindowMs: Int
        }

        struct LLMState: Codable {
            var isEnabled: Bool
            var apiBaseURL: String
            var model: String
            var systemPrompt: String
            var timeoutSeconds: Int
            var apiKeyPresent: Bool
        }

        var loginStatus: String
        var recordingState: String
        var currentText: String
        var lastNotification: String?
        var overlay: OverlaySnapshot?
        var shortcut: ShortcutState?
        var llm: LLMState?
    }

    private static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool {
        environment["VOICEINPUT_AUTOMATION"] == "1"
    }

    static var openSettingsOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_OPEN_SETTINGS"] == "1"
    }

    static var simulateAuthExpiredOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_AUTH_EXPIRED"] == "1"
    }

    static var autoRecordOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_AUTO_RECORD"] == "1"
    }

    static var autoUninstallOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_AUTO_UNINSTALL"] == "1"
    }

    static var autoStopAfterMilliseconds: Int? {
        guard let value = environment["VOICEINPUT_AUTOMATION_AUTO_STOP_MS"] else {
            return nil
        }
        return Int(value)
    }

    static var showCapsLockGuideOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_SHOW_CAPSLOCK_GUIDE"] == "1"
    }

    static var checkUpdateOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_CHECK_UPDATE"] == "1"
    }

    static var shortcutOverride: ShortcutConfiguration? {
        guard let keyRaw = environment["VOICEINPUT_AUTOMATION_SET_TRIGGER_KEY"],
              let triggerKey = ShortcutTriggerKey(rawValue: keyRaw) else {
            return nil
        }

        let mode = ShortcutMode(
            rawValue: environment["VOICEINPUT_AUTOMATION_SET_MODE"] ?? ShortcutMode.hold.rawValue
        ) ?? .hold
        let doubleTap = Int(environment["VOICEINPUT_AUTOMATION_SET_DOUBLE_TAP_MS"] ?? "")
            ?? ShortcutConfiguration.defaultDoubleTapWindowMs
        let secondaryTriggerKey = ShortcutTriggerKey(
            rawValue: environment["VOICEINPUT_AUTOMATION_SET_SECONDARY_TRIGGER_KEY"] ?? ""
        ) ?? .rightCommand
        let secondaryMode = ShortcutMode(
            rawValue: environment["VOICEINPUT_AUTOMATION_SET_SECONDARY_MODE"] ?? ShortcutMode.none.rawValue
        ) ?? .none
        return ShortcutConfiguration(
            primary: ShortcutTriggerSlot(triggerKey: triggerKey, mode: mode),
            secondary: ShortcutTriggerSlot(triggerKey: secondaryTriggerKey, mode: secondaryMode),
            doubleTapWindowMs: doubleTap
        )
    }

    @MainActor
    static var llmOverrideDraft: LLMSettingsDraft? {
        guard environment["VOICEINPUT_AUTOMATION_SAVE_LLM"] == "1" else { return nil }

        let current = SettingsStore.shared.llmDraft()
        return LLMSettingsDraft(
            configuration: LLMConfiguration(
                isEnabled: environment["VOICEINPUT_AUTOMATION_SET_LLM_ENABLE"] == "1",
                apiBaseURL: environment["VOICEINPUT_AUTOMATION_SET_LLM_BASE_URL"] ?? current.apiBaseURL,
                model: environment["VOICEINPUT_AUTOMATION_SET_LLM_MODEL"] ?? current.model,
                systemPrompt: environment["VOICEINPUT_AUTOMATION_SET_LLM_SYSTEM_PROMPT"] ?? current.systemPrompt,
                timeoutSeconds: Int(environment["VOICEINPUT_AUTOMATION_SET_LLM_TIMEOUT"] ?? "") ?? current.timeoutSeconds
            ),
            apiKey: environment["VOICEINPUT_AUTOMATION_SET_LLM_API_KEY"] ?? current.apiKey
        )
    }

    static var resetPromptOnLaunch: Bool {
        environment["VOICEINPUT_AUTOMATION_RESET_PROMPT"] == "1"
    }

    static var mockLoginStatus: LoginStatus? {
        switch environment["VOICEINPUT_AUTOMATION_LOGIN_STATUS"] {
        case "loggedIn":
            return .loggedIn
        case "notLoggedIn":
            return .notLoggedIn
        default:
            return nil
        }
    }

    static var shouldMockASR: Bool {
        !mockASRPartials.isEmpty || mockASRFinal != nil
    }

    static var mockASRPartials: [String] {
        splitList(environment["VOICEINPUT_AUTOMATION_ASR_PARTIALS"])
    }

    static var mockASRFinal: String? {
        environment["VOICEINPUT_AUTOMATION_ASR_FINAL"]
    }

    static var mockASRWaveformValues: [Double] {
        splitList(environment["VOICEINPUT_AUTOMATION_RMS"]).compactMap(Double.init)
    }

    static var stateFileURL: URL? {
        guard let path = environment["VOICEINPUT_AUTOMATION_STATE_PATH"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    @MainActor
    static func writeState(appState: AppState, overlay: OverlaySnapshot?, settingsStore: SettingsStore? = nil) {
        guard isEnabled, let url = stateFileURL else { return }
        let store = settingsStore
        let state = State(
            loginStatus: appState.loginStatus.rawValue,
            recordingState: String(describing: appState.recordingState),
            currentText: appState.currentText,
            lastNotification: appState.lastNotification,
            overlay: overlay,
            shortcut: store.map {
                .init(
                    triggerKey: $0.shortcutConfiguration.primary.triggerKey.rawValue,
                    mode: $0.shortcutConfiguration.primary.mode.rawValue,
                    secondaryTriggerKey: $0.shortcutConfiguration.secondary.triggerKey.rawValue,
                    secondaryMode: $0.shortcutConfiguration.secondary.mode.rawValue,
                    doubleTapWindowMs: $0.shortcutConfiguration.doubleTapWindowMs
                )
            },
            llm: store.map {
                .init(
                    isEnabled: $0.llmConfiguration.isEnabled,
                    apiBaseURL: $0.llmConfiguration.apiBaseURL,
                    model: $0.llmConfiguration.model,
                    systemPrompt: $0.llmConfiguration.systemPrompt,
                    timeoutSeconds: $0.llmConfiguration.timeoutSeconds,
                    apiKeyPresent: !$0.apiKey.isEmpty
                )
            }
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func splitList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: "|").map { String($0) }
    }
}
