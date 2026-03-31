import Foundation
import Combine

@MainActor
class TranscriptionManager {
    private let appState: AppState
    private let webViewManager: WebViewManager
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager

    init(
        appState: AppState,
        webViewManager: WebViewManager,
        overlayPanel: OverlayPanel,
        hotkeyManager: HotkeyManager
    ) {
        self.appState = appState
        self.webViewManager = webViewManager
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
    }

    func start() {
        // Wire up hotkey events
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            print("[TranscriptionManager] Received hotkey event: \(event)")
            Task { @MainActor in
                guard let self = self else {
                    print("[TranscriptionManager] ⚠️ self is nil in hotkey handler")
                    return
                }
                switch event {
                case .toggleRecording:
                    self.handleToggle()
                case .cancel:
                    self.handleCancel()
                }
            }
        }

        // Wire up ASR WebSocket messages
        webViewManager.onASRMessage = { [weak self] type, text in
            print("[TranscriptionManager] Received ASR message: type=\(type), text=\(text ?? "nil")")
            Task { @MainActor in
                guard let self = self else { return }
                self.handleASRMessage(type: type, text: text)
            }
        }

        hotkeyManager.start()
        print("[TranscriptionManager] ✅ Started")
    }

    // MARK: - Toggle Recording

    private func handleToggle() {
        print("[TranscriptionManager] handleToggle called, current state: \(appState.recordingState)")
        switch appState.recordingState {
        case .idle:
            startRecording()
        case .starting, .recording:
            stopRecording()
        case .stopping:
            // Already stopping, ignore
            break
        }
    }

    private func startRecording() {
        guard appState.loginStatus == .loggedIn else {
            print("[TranscriptionManager] ⚠️ Not logged in (status=\(appState.loginStatus)), showing login window")
            webViewManager.showLoginWindow()
            return
        }

        print("[TranscriptionManager] 🎤 Starting recording...")
        appState.recordingState = .starting
        appState.transcriptionText = ""
        appState.errorMessage = nil
        overlayPanel.showOverlay()
        print("[TranscriptionManager] Overlay shown, clicking ASR button...")

        webViewManager.clickAsrButton { [weak self] clicked in
            guard let self = self else { return }
            Task { @MainActor in
                if !clicked {
                    print("[TranscriptionManager] ⚠️ ASR button not found in DOM")
                    self.appState.errorMessage = "语音按钮未找到，请稍后重试"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.resetToIdle()
                    }
                }
            }
        }
    }

    private func stopRecording() {
        print("[TranscriptionManager] ⏹ Stopping recording...")
        appState.recordingState = .stopping
        webViewManager.clickAsrButton()

        // Timeout: if no finish event within 5 seconds, force complete
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if appState.recordingState == .stopping {
                completeTranscription()
            }
        }
    }

    // MARK: - Cancel

    private func handleCancel() {
        guard appState.recordingState != .idle else { return }

        // If ASR is active, click button to deactivate
        if appState.recordingState == .recording || appState.recordingState == .starting {
            webViewManager.clickAsrButton()
        }

        resetToIdle()
    }

    // MARK: - ASR Message Handling

    private func handleASRMessage(type: String, text: String?) {
        switch type {
        case "open":
            print("[TranscriptionManager] ASR WebSocket opened")
            if appState.recordingState == .starting {
                appState.recordingState = .recording
            }

        case "result":
            if let text = text, !text.isEmpty {
                appState.transcriptionText = text
                if appState.recordingState == .starting {
                    appState.recordingState = .recording
                }
            }

        case "finish":
            if appState.recordingState == .stopping || appState.recordingState == .recording {
                completeTranscription()
            }

        case "close":
            if appState.recordingState == .stopping {
                completeTranscription()
            } else if appState.recordingState == .recording || appState.recordingState == .starting {
                appState.errorMessage = "连接已断开"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.resetToIdle()
                }
            }

        case "error":
            appState.errorMessage = "语音识别出错"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.resetToIdle()
            }

        default:
            break
        }
    }

    // MARK: - Completion

    private func completeTranscription() {
        let text = appState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[TranscriptionManager] ✅ Completing transcription, text=\"\(text)\"")

        if !text.isEmpty {
            PasteHelper.copyAndPaste(text)
        }

        // After ASR finishes, doubao tries to send text to LLM (/chat/completion).
        // Even though the request is blocked, the UI shows a "break" button instead of
        // the ASR button until the request times out. Click it to restore normal state.
        webViewManager.clickBreakButton()

        resetToIdle()
    }

    private func resetToIdle() {
        print("[TranscriptionManager] Resetting to idle")
        appState.recordingState = .idle
        appState.showOverlay = false
        appState.errorMessage = nil
        overlayPanel.hideOverlay()

        // Clear transcription text after a short delay (so paste can complete)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.appState.transcriptionText = ""
        }
    }
}
