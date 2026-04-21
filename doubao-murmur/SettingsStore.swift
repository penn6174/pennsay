import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum Keys {
        static let shortcutTriggerKey = "shortcut.triggerKey"
        static let shortcutMode = "shortcut.mode"
        static let shortcutDoubleTapWindowMs = "shortcut.doubleTapWindowMs"
        static let llmConfiguration = "llm.configuration"
    }

    @Published private(set) var shortcutConfiguration: ShortcutConfiguration
    @Published private(set) var llmConfiguration: LLMConfiguration
    @Published private(set) var apiKey: String

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

        if let data = defaults.data(forKey: Keys.llmConfiguration),
           let config = try? JSONDecoder().decode(LLMConfiguration.self, from: data) {
            llmConfiguration = config
        } else {
            llmConfiguration = .default
        }

        apiKey = KeychainStore.readAPIKey()
        if apiKey.isEmpty, llmConfiguration.isEnabled {
            llmConfiguration.isEnabled = false
            persistLLMConfiguration()
        }
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
}
