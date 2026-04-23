import AVFoundation
import Combine
import Foundation
import AppKit

@MainActor
final class TranscriptionManager {
    private let log = AppLog(category: "Transcription")
    private let appState: AppState
    private let webViewManager: WebViewManager
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager
    private let settingsStore: SettingsStore
    private let asrClient = DoubaoASRClient()
    private let audioCapture = AudioCaptureManager()
    private let llmRefiner = LLMRefiner()

    private var cancellables = Set<AnyCancellable>()
    private var waveformProcessor = WaveformLevelProcessor()
    private var currentTranscription = ""
    private var usingCachedParams = false
    private var awaitingFinalResult = false
    private var mockWorkItems: [DispatchWorkItem] = []
    private var tailStopWorkItem: DispatchWorkItem?
    private var finalStabilityWorkItem: DispatchWorkItem?
    private var finalHardTimeoutWorkItem: DispatchWorkItem?
    private var targetApplication: NSRunningApplication?

    private let stopTailCaptureDelay: TimeInterval = 0.20
    private let finalStabilityDelay: TimeInterval = 0.60
    private let finalHardTimeout: TimeInterval = 2.50

    var onAuthExpired: (() -> Void)?

    init(
        appState: AppState,
        webViewManager: WebViewManager,
        overlayPanel: OverlayPanel,
        hotkeyManager: HotkeyManager,
        settingsStore: SettingsStore
    ) {
        self.appState = appState
        self.webViewManager = webViewManager
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
        self.settingsStore = settingsStore
    }

    func start() {
        wireHotkeys()
        wireASR()
        wireAudioCapture()
        wireOverlay()

        settingsStore.$shortcutConfiguration
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                self?.hotkeyManager.updateConfiguration(config)
            }
            .store(in: &cancellables)

        hotkeyManager.start()
        log.notice("transcription manager started")
    }

    func automationStartRecording() {
        startRecording()
    }

    func automationStopRecording() {
        stopRecording()
    }

    private func wireHotkeys() {
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .startRecording:
                    self.startRecording()
                case .stopRecording:
                    self.stopRecording()
                case .toggleRecording:
                    self.toggleRecording()
                case .cancel:
                    self.cancelRecording()
                }
            }
        }
    }

    private func wireASR() {
        asrClient.onOpen = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.appState.recordingState == .starting {
                    self.appState.recordingState = .recording
                    self.hotkeyManager.setEscapeHandlingEnabled(true)
                    self.overlayPanel.showListening(text: self.currentTranscription.isEmpty ? AppEnvironment.listeningPlaceholder : self.currentTranscription)
                }
                self.log.notice("ASR connection open")
            }
        }

        asrClient.onResult = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.currentTranscription = trimmed
                self.appState.currentText = trimmed
                self.log.info("Partial: \(trimmed)")
                if self.appState.recordingState == .starting {
                    self.appState.recordingState = .recording
                }
                self.overlayPanel.showListening(text: trimmed)
                if self.awaitingFinalResult {
                    self.scheduleStableCompletion()
                }
            }
        }

        asrClient.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.awaitingFinalResult = false
                self.cancelFinalizationTimers()
                if self.appState.recordingState == .stopping || self.appState.recordingState == .recording {
                    self.completeTranscription()
                }
            }
        }

        asrClient.onAudioDrained = { [weak self] in
            Task { @MainActor in
                guard let self, self.appState.recordingState == .stopping else { return }
                self.log.notice("ASR audio queue drained")
                self.scheduleStableCompletion()
            }
        }

        asrClient.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.log.error("ASR error: \(error?.localizedDescription ?? "unknown")")
                if self.usingCachedParams {
                    self.handleAuthFailure()
                    return
                }
                self.overlayPanel.showError(text: "连接出错")
                self.resetToIdle(after: 1.2)
            }
        }

        asrClient.onAuthError = { [weak self] in
            Task { @MainActor in
                self?.handleAuthFailure()
            }
        }
    }

    private func wireAudioCapture() {
        audioCapture.onAudioData = { [weak self] data in
            self?.asrClient.sendAudio(data)
        }
        audioCapture.onRMS = { [weak self] rms in
            Task { @MainActor in
                guard let self else { return }
                let levels = self.waveformProcessor.process(
                    rms: rms,
                    randomValues: nil
                ).map { CGFloat($0) }
                self.overlayPanel.updateWaveform(levels: levels)
            }
        }
    }

    private func wireOverlay() {
        overlayPanel.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelRecording()
            }
        }
    }

    private func toggleRecording() {
        switch appState.recordingState {
        case .idle:
            startRecording()
        case .starting, .recording:
            stopRecording()
        case .stopping, .refining:
            break
        }
    }

    private func startRecording() {
        guard appState.recordingState == .idle else {
            return
        }

        guard appState.loginStatus == .loggedIn else {
            log.notice("recording requested while logged out")
            webViewManager.showLoginWindow()
            return
        }

        if !AutomationController.isEnabled {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                log.notice("microphone permission not determined, requesting")
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    LogStore.write("[permission] microphone granted=\(granted)")
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if granted {
                            self.startRecording()
                        } else {
                            self.overlayPanel.showError(text: "需要麦克风权限 请到系统设置开启")
                            self.resetToIdle(after: 2.0)
                        }
                    }
                }
                return
            case .denied, .restricted:
                log.error("microphone permission denied")
                overlayPanel.showError(text: "麦克风权限被拒绝 请到系统设置开启")
                resetToIdle(after: 2.0)
                return
            @unknown default:
                break
            }
        }

        log.notice("start recording")
        targetApplication = NSWorkspace.shared.frontmostApplication
        log.notice("target application = \(targetApplication?.localizedName ?? "nil")")
        cancelFinalizationTimers()
        asrClient.prepareForNewSession()
        currentTranscription = ""
        appState.currentText = ""
        appState.recordingState = .starting
        waveformProcessor.reset()
        overlayPanel.showListening()
        overlayPanel.updateWaveform(levels: Array(repeating: 0.12, count: 5))
        hotkeyManager.setEscapeHandlingEnabled(true)

        if AutomationController.shouldMockASR {
            startMockASRSession()
            return
        }

        do {
            try audioCapture.startCapture()
        } catch {
            log.error("audio capture failed: \(error.localizedDescription)")
            overlayPanel.showError(text: "麦克风启动失败")
            resetToIdle(after: 1.2)
            return
        }

        Task {
            if let cachedParams = ASRParamsStore.load() {
                usingCachedParams = true
                asrClient.connect(params: cachedParams)
                return
            }

            if webViewManager.isActive,
               let params = await webViewManager.extractASRParams() {
                usingCachedParams = false
                ASRParamsStore.save(params)
                asrClient.connect(params: params)
                return
            }

            overlayPanel.showError(text: "无法获取连接参数 请重新登录")
            resetToIdle(after: 1.2)
        }
    }

    private func stopRecording() {
        guard appState.recordingState == .starting || appState.recordingState == .recording else {
            return
        }
        log.notice("stop recording")
        appState.recordingState = .stopping

        if AutomationController.shouldMockASR {
            currentTranscription = AutomationController.mockASRFinal ?? currentTranscription
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.completeTranscription()
            }
            return
        }

        awaitingFinalResult = true

        tailStopWorkItem?.cancel()
        let tailStop = DispatchWorkItem { [weak self] in
            guard let self, self.appState.recordingState == .stopping else { return }
            self.audioCapture.stopCapture()
            self.asrClient.finishSending()
        }
        tailStopWorkItem = tailStop
        DispatchQueue.main.asyncAfter(deadline: .now() + stopTailCaptureDelay, execute: tailStop)

        finalHardTimeoutWorkItem?.cancel()
        let hardTimeout = DispatchWorkItem { [weak self] in
            guard let self, self.appState.recordingState == .stopping else { return }
            self.log.notice("ASR final hard timeout reached")
            self.awaitingFinalResult = false
            self.completeTranscription()
        }
        finalHardTimeoutWorkItem = hardTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + finalHardTimeout, execute: hardTimeout)
    }

    private func completeTranscription() {
        let originalText = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        log.notice("complete transcription originalLength=\(originalText.count)")

        guard !originalText.isEmpty else {
            resetToIdle(after: 0)
            return
        }

        let llmConfiguration = settingsStore.llmConfiguration
        if llmConfiguration.isEnabled && settingsStore.isLLMReady {
            appState.recordingState = .refining
            overlayPanel.showRefining()
            Task {
                await refineAndPaste(originalText, configuration: llmConfiguration)
            }
            return
        }

        pasteAndDismiss(originalText)
    }

    private func refineAndPaste(_ originalText: String, configuration: LLMConfiguration) async {
        do {
            let refined = try await llmRefiner.refine(
                text: originalText,
                configuration: configuration,
                apiKey: settingsStore.apiKey
            ) { [weak self] streamedText in
                Task { @MainActor in
                    self?.overlayPanel.updateText(streamedText.isEmpty ? AppEnvironment.refiningPlaceholder : streamedText)
                }
            }

            let finalText = refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? originalText : refined
            overlayPanel.updateText(finalText)
            pasteAndDismiss(finalText)
        } catch let error as LLMRefinerError {
            handleLLMFallback(error: error, originalText: originalText)
        } catch {
            handleLLMFallback(error: .unreachable, originalText: originalText)
        }
    }

    private func handleLLMFallback(error: LLMRefinerError, originalText: String) {
        let message: String
        switch error {
        case .timeout:
            message = "LLM timeout"
        case .httpError(let statusCode, _):
            message = "LLM error: \(statusCode)"
        case .unreachable:
            message = "LLM unreachable"
        default:
            message = error.localizedDescription
        }

        appState.lastNotification = message
        NotificationHelper.show(title: AppEnvironment.displayName, body: message)
        log.error("LLM fallback triggered: \(message)")
        overlayPanel.updateText(originalText)
        pasteAndDismiss(originalText)
    }

    private func pasteAndDismiss(_ text: String) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            resetToIdle(after: 0)
            return
        }
        log.notice("pasting into \(targetApplication?.localizedName ?? "nil")")
        overlayPanel.hideOverlay(animated: false)
        PasteHelper.copyAndPaste(finalText, targetApplication: targetApplication)
        resetToIdle(after: 0.25)

        // Emit onboarding signal: first successful paste is the right moment to
        // ask about Launch at Login (sits after Accessibility + Microphone
        // system prompts, avoids stacking native dialogs).
        NotificationCenter.default.post(
            name: Notification.Name("PennSayDidCompletePaste"),
            object: nil
        )
    }

    private func cancelRecording() {
        guard appState.recordingState != .idle else { return }
        log.notice("cancel recording")
        awaitingFinalResult = false
        cancelFinalizationTimers()
        cancelMockASRSession()
        audioCapture.stopCapture()
        asrClient.disconnect()
        resetToIdle(after: 0)
    }

    private func handleAuthFailure() {
        log.notice("auth failure detected")
        ASRParamsStore.clear()
        usingCachedParams = false
        audioCapture.stopCapture()
        asrClient.disconnect()
        appState.loginStatus = .notLoggedIn
        resetToIdle(after: 0)
        onAuthExpired?()
    }

    private func resetToIdle(after delay: TimeInterval) {
        let reset = { [weak self] in
            guard let self else { return }
            self.awaitingFinalResult = false
            self.cancelFinalizationTimers()
            self.cancelMockASRSession()
            self.currentTranscription = ""
            self.targetApplication = nil
            self.audioCapture.stopCapture()
            self.asrClient.disconnect()
            self.appState.recordingState = .idle
            self.appState.currentText = ""
            self.hotkeyManager.setEscapeHandlingEnabled(false)
            self.overlayPanel.hideOverlay(animated: true)
            self.usingCachedParams = false
        }

        if delay == 0 {
            reset()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                reset()
            }
        }
    }

    private func startMockASRSession() {
        appState.recordingState = .recording
        overlayPanel.showListening()

        let partials = AutomationController.mockASRPartials
        let rmsValues = AutomationController.mockASRWaveformValues.isEmpty
            ? [0.01, 0.03, 0.08, 0.12, 0.04]
            : AutomationController.mockASRWaveformValues

        for (index, partial) in partials.enumerated() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.appState.recordingState == .recording else { return }
                self.currentTranscription = partial
                self.appState.currentText = partial
                self.log.info("Partial: \(partial)")
                let rms = rmsValues[index % rmsValues.count]
                let levels = self.waveformProcessor.process(
                    rms: rms,
                    randomValues: [0, 0, 0, 0, 0]
                ).map { CGFloat($0) }
                self.overlayPanel.showListening(text: partial)
                self.overlayPanel.updateWaveform(levels: levels)
            }
            mockWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(index + 1), execute: workItem)
        }
    }

    private func cancelMockASRSession() {
        mockWorkItems.forEach { $0.cancel() }
        mockWorkItems.removeAll()
    }

    private func scheduleStableCompletion() {
        finalStabilityWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.appState.recordingState == .stopping else { return }
            self.awaitingFinalResult = false
            self.cancelFinalizationTimers()
            self.completeTranscription()
        }
        finalStabilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + finalStabilityDelay, execute: workItem)
    }

    private func cancelFinalizationTimers() {
        tailStopWorkItem?.cancel()
        tailStopWorkItem = nil
        finalStabilityWorkItem?.cancel()
        finalStabilityWorkItem = nil
        finalHardTimeoutWorkItem?.cancel()
        finalHardTimeoutWorkItem = nil
    }
}
