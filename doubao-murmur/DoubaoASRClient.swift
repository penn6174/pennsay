import Foundation

/// Parameters needed to establish a WSS ASR connection.
/// Codable so they can be persisted to a local config file.
struct DoubaoASRParams: Codable {
    /// Cookie name→value pairs for authentication.
    let cookies: [String: String]
    let deviceId: String
    let webId: String

    /// Build the Cookie header string for HTTP/WSS requests.
    var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Convenience init from HTTPCookie array (extracted from WKWebView).
    init(httpCookies: [HTTPCookie], deviceId: String, webId: String) {
        var dict = [String: String]()
        for cookie in httpCookies {
            dict[cookie.name] = cookie.value
        }
        self.cookies = dict
        self.deviceId = deviceId
        self.webId = webId
    }

    init(cookies: [String: String], deviceId: String, webId: String) {
        self.cookies = cookies
        self.deviceId = deviceId
        self.webId = webId
    }
}

/// Native WebSocket client for Doubao's streaming ASR service.
/// Connects to `wss://ws-samantha.doubao.com/samantha/audio/asr` with cookie auth,
/// sends raw Int16 LE PCM audio data, and receives JSON transcription results.
class DoubaoASRClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private(set) var isConnected = false

    /// Audio data is queued before and after the WebSocket opens, then sent in
    /// order. This is important for very short recordings: stop can happen
    /// before the WSS ping completes, and those early chunks must not be
    /// discarded.
    private var pendingAudioBuffer: [Data] = []
    private var isSendingAudio = false
    private var finishRequested = false
    private let bufferLock = NSLock()

    // Callbacks (may be called from URLSession's background thread)
    var onOpen: (() -> Void)?
    var onResult: ((_ text: String) -> Void)?
    var onFinish: (() -> Void)?
    var onAudioDrained: (() -> Void)?
    var onError: ((_ error: Error?) -> Void)?
    /// Fired when the server indicates cookie/auth failure (distinct from generic errors).
    var onAuthError: (() -> Void)?

    func prepareForNewSession(initialSilenceMilliseconds: Int = 200) {
        bufferLock.lock()
        pendingAudioBuffer.removeAll()
        isSendingAudio = false
        finishRequested = false
        if initialSilenceMilliseconds > 0 {
            pendingAudioBuffer.append(contentsOf: Self.silenceChunks(milliseconds: initialSilenceMilliseconds))
        }
        bufferLock.unlock()
    }

    func connect(params: DoubaoASRParams) {
        var components = URLComponents(string: "wss://ws-samantha.doubao.com/samantha/audio/asr")!
        components.queryItems = [
            URLQueryItem(name: "version_code", value: "20800"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "aid", value: "497858"),
            URLQueryItem(name: "real_aid", value: "497858"),
            URLQueryItem(name: "pkg_type", value: "release_version"),
            URLQueryItem(name: "device_id", value: params.deviceId),
            URLQueryItem(name: "pc_version", value: "3.12.3"),
            URLQueryItem(name: "web_id", value: params.webId),
            URLQueryItem(name: "tea_uuid", value: params.webId),
            URLQueryItem(name: "region", value: ""),
            URLQueryItem(name: "sys_region", value: ""),
            URLQueryItem(name: "samantha_web", value: "1"),
            URLQueryItem(name: "use-olympus-account", value: "1"),
            URLQueryItem(name: "web_tab_id", value: UUID().uuidString),
            URLQueryItem(name: "format", value: "pcm"),
        ]

        guard let url = components.url else {
            print("[DoubaoASRClient] ❌ Failed to build WSS URL")
            onError?(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(params.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        request.timeoutInterval = 5

        print("[DoubaoASRClient] Connecting...")

        let task = URLSession.shared.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        receiveMessage()

        // Verify connection is alive
        task.sendPing { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("[DoubaoASRClient] ❌ Connection failed: \(error.localizedDescription)")
                self.onError?(error)
            } else {
                print("[DoubaoASRClient] ✅ Connected")
                self.isConnected = true
                self.drainAudioQueue()
                self.onOpen?()
            }
        }
    }

    /// Send raw PCM audio data. Thread-safe.
    /// If the WebSocket is not yet connected, data is buffered and flushed on connect.
    func sendAudio(_ data: Data) {
        bufferLock.lock()
        if !finishRequested {
            pendingAudioBuffer.append(data)
        }
        bufferLock.unlock()
        drainAudioQueue()
    }

    /// Signal that no more microphone audio will be sent. We append a short
    /// silence tail so the upstream VAD can settle, then keep the WebSocket
    /// open to receive the final result/finish event.
    func finishSending(trailingSilenceMilliseconds: Int = 450) {
        bufferLock.lock()
        if !finishRequested {
            finishRequested = true
            if trailingSilenceMilliseconds > 0 {
                pendingAudioBuffer.append(contentsOf: Self.silenceChunks(milliseconds: trailingSilenceMilliseconds))
            }
        }
        bufferLock.unlock()
        print("[DoubaoASRClient] Finished sending audio, waiting for server response")
        drainAudioQueue()
    }

    func disconnect() {
        isConnected = false
        bufferLock.lock()
        pendingAudioBuffer.removeAll()
        isSendingAudio = false
        finishRequested = false
        bufferLock.unlock()
        guard webSocketTask != nil else { return }
        webSocketTask?.cancel(with: .normalClosure, reason: "1000-".data(using: .utf8))
        webSocketTask = nil
        print("[DoubaoASRClient] Disconnected")
    }

    /// Send queued audio chunks one at a time. URLSessionWebSocketTask sends are
    /// asynchronous, so firing many sends concurrently risks reordering or
    /// losing the exact tail during stop.
    private func drainAudioQueue() {
        bufferLock.lock()
        guard isConnected, !isSendingAudio, let task = webSocketTask else {
            bufferLock.unlock()
            return
        }

        guard !pendingAudioBuffer.isEmpty else {
            let shouldNotifyDrain = finishRequested
            bufferLock.unlock()
            if shouldNotifyDrain {
                onAudioDrained?()
            }
            return
        }

        let chunk = pendingAudioBuffer.removeFirst()
        isSendingAudio = true
        bufferLock.unlock()

        task.send(.data(chunk)) { [weak self] error in
            guard let self else { return }
            self.bufferLock.lock()
            self.isSendingAudio = false
            self.bufferLock.unlock()

            if let error = error {
                print("[DoubaoASRClient] ⚠️ Send error: \(error.localizedDescription)")
                self.onError?(error)
                return
            }

            self.drainAudioQueue()
        }
    }

    private static func silenceChunks(milliseconds: Int) -> [Data] {
        let bytesPerSecond = 16_000 * 2
        let totalBytes = max(0, milliseconds) * bytesPerSecond / 1000
        guard totalBytes > 0 else { return [] }

        let chunkSize = 4096
        var chunks: [Data] = []
        var remaining = totalBytes
        while remaining > 0 {
            let count = min(chunkSize, remaining)
            chunks.append(Data(repeating: 0, count: count))
            remaining -= count
        }
        return chunks
    }

    // MARK: - Receive Loop

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                if self.isConnected {
                    print("[DoubaoASRClient] ❌ Receive error: \(error.localizedDescription)")
                    self.isConnected = false
                    self.onError?(error)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let code = json["code"] as? Int ?? 0
        let event = json["event"] as? String ?? ""
        let message = json["message"] as? String ?? ""

        // Detect auth/cookie errors (non-zero code with auth-related message)
        if code != 0 {
            let lowerMsg = message.lowercased()
            // 709599054 = "Invalid" per spec; also check for cookie/auth keywords
            if code == 709599054
                || lowerMsg.contains("cookie")
                || lowerMsg.contains("auth")
                || lowerMsg.contains("login")
                || lowerMsg.contains("session")
                || lowerMsg.contains("unauthorized")
                || lowerMsg.contains("expired") {
                print("[DoubaoASRClient] ⚠️ Auth error detected: code=\(code), message=\(message)")
                isConnected = false
                onAuthError?()
                return
            }
        }

        switch event {
        case "result":
            if let result = json["result"] as? [String: Any],
               let recognizedText = result["Text"] as? String,
               !recognizedText.isEmpty {
                onResult?(recognizedText)
            }
        case "finish":
            print("[DoubaoASRClient] Received finish event")
            onFinish?()
        default:
            break
        }
    }
}
