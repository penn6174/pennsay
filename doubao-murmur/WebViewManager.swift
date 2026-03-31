import Foundation
import WebKit
import Combine

@MainActor
class WebViewManager: NSObject {
    private let appState: AppState
    private var webView: WKWebView!
    private var webViewWindow: NSWindow!
    private var cancellables = Set<AnyCancellable>()

    // Callback for ASR messages
    var onASRMessage: ((_ type: String, _ text: String?) -> Void)?
    // Callback for login status changes
    var onLoginStatusChange: ((_ status: String, _ nickname: String?) -> Void)?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        // User content controller for JS injection + message handling
        let userContent = WKUserContentController()

        // Inject WebSocket interceptor at document start
        if let wsJS = loadJSResource("inject-websocket") {
            let wsScript = WKUserScript(source: wsJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            userContent.addUserScript(wsScript)
        }

        // Inject DOM helpers at document end
        if let domJS = loadJSResource("inject-dom") {
            let domScript = WKUserScript(source: domJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            userContent.addUserScript(domScript)
        }

        // Register message handler for ASR
        userContent.add(self, name: "asrHandler")

        // Block /chat/completion requests via content rule list
        let blockRule = """
        [{
            "trigger": {"url-filter": ".*/chat/completion.*"},
            "action": {"type": "block"}
        }]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "BlockCompletion",
            encodedContentRuleList: blockRule
        ) { [weak userContent] ruleList, error in
            if let ruleList = ruleList {
                userContent?.add(ruleList)
            }
        }

        config.userContentController = userContent
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Allow media capture without gesture
        if config.responds(to: Selector(("setMediaTypesRequiringUserActionForPlayback:"))) {
            config.mediaTypesRequiringUserActionForPlayback = []
        }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

        // Create hidden window to host webview
        webViewWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        webViewWindow.title = "Doubao Murmur - Login"
        webViewWindow.contentView = webView
        webViewWindow.isReleasedWhenClosed = false
        // Start hidden
        webViewWindow.orderOut(nil)
    }

    private func loadJSResource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            print("[WebViewManager] JS resource not found: \(name)")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Public API

    func load() {
        let url = URL(string: "https://www.doubao.com/chat")!
        webView.load(URLRequest(url: url))
    }

    func reload() {
        appState.loginStatus = .checking
        webView.reload()
    }

    func showLoginWindow() {
        webViewWindow.center()
        webViewWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideLoginWindow() {
        webViewWindow.orderOut(nil)
    }

    func clickAsrButton(completion: ((Bool) -> Void)? = nil) {
        webView.evaluateJavaScript("window.__doubaoMurmur.clickAsrButton()") { result, error in
            if let error = error {
                print("[WebViewManager] clickAsrButton error: \(error)")
                completion?(false)
                return
            }
            let clicked = result as? Bool ?? false
            print("[WebViewManager] clickAsrButton result: \(clicked)")
            completion?(clicked)
        }
    }

    /// Try to click the break button that appears after ASR finishes.
    /// Retries up to `maxRetries` times with `interval` between attempts,
    /// because the button may appear with a slight delay after the blocked request starts.
    func clickBreakButton(maxRetries: Int = 5, interval: TimeInterval = 0.5) {
        var attempt = 0
        func tryClick() {
            webView.evaluateJavaScript("window.__doubaoMurmur.clickBreakButton()") { result, error in
                let clicked = result as? Bool ?? false
                attempt += 1
                if clicked {
                    print("[WebViewManager] Break button clicked on attempt \(attempt)")
                } else if attempt < maxRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                        tryClick()
                    }
                } else {
                    print("[WebViewManager] Break button not found after \(maxRetries) attempts (may not have appeared)")
                }
            }
        }
        tryClick()
    }

    func getAsrButtonState(completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__doubaoMurmur.getAsrButtonState()") { result, error in
            completion((result as? String) ?? "unknown")
        }
    }

    func checkLoginState() {
        // Login detection is now handled by fetch/XHR interception in inject-websocket.js.
        // The profile API call (/alice/profile/self) is intercepted and sends a 'login' message.
        // As a fallback, check the DOM after a delay.
        webView.evaluateJavaScript("window.__doubaoMurmur.isLoginButtonPresent()") { [weak self] result, error in
            guard let self = self else { return }
            Task { @MainActor in
                if let isLoginButton = result as? Bool, isLoginButton {
                    // Login button present means definitely not logged in
                    if self.appState.loginStatus == .checking {
                        self.appState.loginStatus = .notLoggedIn
                    }
                }
            }
        }
    }

    func logout() {
        let dataStore = webView.configuration.websiteDataStore
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: allTypes) { records in
            let doubaoRecords = records.filter { $0.displayName.contains("doubao") }
            dataStore.removeData(ofTypes: allTypes, for: doubaoRecords) { [weak self] in
                Task { @MainActor in
                    self?.appState.loginStatus = .notLoggedIn
                    self?.load()
                }
            }
        }
    }
}

// MARK: - WKScriptMessageHandler
extension WebViewManager: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "asrHandler",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "login" {
            let status = body["status"] as? String ?? "unknown"
            let nickname = body["nickname"] as? String
            Task { @MainActor in
                self.onLoginStatusChange?(status, nickname)
            }
            return
        }

        if type == "debug" {
            let text = body["text"] as? String ?? ""
            print("[WebViewManager] [JS Debug] \(text)")
            return
        }

        let text = body["text"] as? String

        Task { @MainActor in
            self.onASRMessage?(type, text)
        }
    }
}

// MARK: - WKNavigationDelegate
extension WebViewManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Check login state after page load
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.checkLoginState()
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           url.absoluteString.contains("from_login=1") {
            Task { @MainActor in
                self.appState.loginStatus = .loggedIn
                self.hideLoginWindow()
            }
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate
extension WebViewManager: WKUIDelegate {
    // Auto-grant microphone permission
    nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    // Handle window.open (e.g., login popups)
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Load in same webview instead of opening new window
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
