import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum Keys {
        static let shortcutTriggerKey = "shortcut.triggerKey"
        static let shortcutMode = "shortcut.mode"
        static let shortcutDoubleTapWindowMs = "shortcut.doubleTapWindowMs"
        static let llmConfiguration = "llm.configuration"
        static let systemPromptVersion = "llm.systemPromptVersion"
        static let autoCheckEnabled = "updater.autoCheckEnabled"
        static let launchAtLogin = "app.launchAtLogin"
        static let launchAtLoginLastSynced = "app.launchAtLogin.lastSynced"
    }

    @Published private(set) var shortcutConfiguration: ShortcutConfiguration
    @Published private(set) var llmConfiguration: LLMConfiguration
    @Published private(set) var apiKey: String
    @Published private(set) var autoCheckUpdatesEnabled: Bool
    @Published private(set) var launchAtLoginEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let trigger = ShortcutTriggerKey(rawValue: defaults.string(forKey: Keys.shortcutTriggerKey) ?? "")
            ?? .rightOption
        let mode = ShortcutMode(rawValue: defaults.string(forKey: Keys.shortcutMode) ?? "")
            ?? .hold
        let doubleTap = defaults.object(forKey: Keys.shortcutDoubleTapWindowMs) as? Int
            ?? ShortcutConfiguration.defaultDoubleTapWindowMs
        shortcutConfiguration = ShortcutConfiguration(
            triggerKey: trigger,
            mode: mode,
            doubleTapWindowMs: doubleTap
        )
        autoCheckUpdatesEnabled = defaults.object(forKey: Keys.autoCheckEnabled) as? Bool ?? true
        launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        if let data = defaults.data(forKey: Keys.llmConfiguration),
           let config = try? JSONDecoder().decode(LLMConfiguration.self, from: data) {
            llmConfiguration = config
        } else {
            llmConfiguration = .default
        }

        apiKey = KeychainStore.readAPIKey()
        migrateSystemPromptIfNeeded()
        if apiKey.isEmpty, llmConfiguration.isEnabled {
            llmConfiguration.isEnabled = false
            persistLLMConfiguration()
        }

        reconcileLaunchAtLoginPreference()
    }

    var isLLMReady: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateShortcut(_ configuration: ShortcutConfiguration) {
        shortcutConfiguration = configuration
        defaults.set(configuration.triggerKey.rawValue, forKey: Keys.shortcutTriggerKey)
        defaults.set(configuration.mode.rawValue, forKey: Keys.shortcutMode)
        defaults.set(configuration.doubleTapWindowMs, forKey: Keys.shortcutDoubleTapWindowMs)
    }

    func llmDraft() -> LLMSettingsDraft {
        LLMSettingsDraft(configuration: llmConfiguration, apiKey: apiKey)
    }

    func setAutoCheckUpdatesEnabled(_ enabled: Bool) {
        autoCheckUpdatesEnabled = enabled
        defaults.set(enabled, forKey: Keys.autoCheckEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        }
        persistLaunchAtLoginState(enabled)
    }

    func saveLLMConfiguration(from draft: LLMSettingsDraft) throws {
        let normalizedEnabled = draft.isEnabled && !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let configuration = LLMConfiguration(
            isEnabled: normalizedEnabled,
            apiBaseURL: draft.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? LLMConfiguration.default.apiBaseURL
                : draft.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? LLMConfiguration.default.model
                : draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: draft.systemPrompt,
            timeoutSeconds: max(1, draft.timeoutSeconds)
        )

        try KeychainStore.saveAPIKey(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        apiKey = KeychainStore.readAPIKey()
        llmConfiguration = configuration
        persistLLMConfiguration()
    }

    func resetSystemPrompt() {
        llmConfiguration.systemPrompt = LLMConfiguration.defaultPrompt
        persistLLMConfiguration()
    }

    func disableLLM() {
        guard llmConfiguration.isEnabled else { return }
        llmConfiguration.isEnabled = false
        persistLLMConfiguration()
    }

    private func persistLLMConfiguration() {
        guard let data = try? JSONEncoder().encode(llmConfiguration) else { return }
        defaults.set(data, forKey: Keys.llmConfiguration)
    }

    private func migrateSystemPromptIfNeeded() {
        let storedVersion = defaults.object(forKey: Keys.systemPromptVersion) as? Int ?? 0
        guard storedVersion < LLMConfiguration.currentSystemPromptVersion else { return }

        let normalizedPrompt = llmConfiguration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPreviousDefaults = Set(
            LLMConfiguration.knownPreviousDefaultPrompts.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        let shouldReplacePrompt =
            normalizedPrompt.isEmpty ||
            normalizedPreviousDefaults.contains(normalizedPrompt)

        if shouldReplacePrompt {
            llmConfiguration.systemPrompt = LLMConfiguration.defaultPrompt
            persistLLMConfiguration()
        }

        defaults.set(LLMConfiguration.currentSystemPromptVersion, forKey: Keys.systemPromptVersion)
    }

    private func reconcileLaunchAtLoginPreference() {
        guard #available(macOS 13.0, *) else {
            persistLaunchAtLoginState(false)
            return
        }

        let service = SMAppService.mainApp
        let actualEnabled = service.status == .enabled || service.status == .requiresApproval
        let storedEnabled = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        let lastSyncedEnabled = defaults.object(forKey: Keys.launchAtLoginLastSynced) as? Bool ?? actualEnabled

        do {
            if storedEnabled != lastSyncedEnabled {
                if storedEnabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            }
        } catch {
            let resolvedEnabled = service.status == .enabled || service.status == .requiresApproval
            persistLaunchAtLoginState(resolvedEnabled)
            return
        }

        let resolvedEnabled = service.status == .enabled || service.status == .requiresApproval
        if storedEnabled != resolvedEnabled {
            persistLaunchAtLoginState(resolvedEnabled)
        } else {
            persistLaunchAtLoginState(storedEnabled)
        }
    }

    private func persistLaunchAtLoginState(_ enabled: Bool) {
        launchAtLoginEnabled = enabled
        defaults.set(enabled, forKey: Keys.launchAtLogin)
        defaults.set(enabled, forKey: Keys.launchAtLoginLastSynced)
    }
}
