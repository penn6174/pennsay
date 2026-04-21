import Foundation

enum LLMRefinerError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case timeout
    case unreachable
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "LLM API Key 未配置"
        case .invalidBaseURL:
            return "LLM Base URL 无效"
        case .invalidResponse:
            return "LLM 返回内容无效"
        case .timeout:
            return "LLM timeout"
        case .unreachable:
            return "LLM unreachable"
        case let .httpError(statusCode, _):
            return "LLM error: \(statusCode)"
        }
    }
}

struct LLMRefiner {
    private let log = AppLog(category: "LLMRefiner")

    func refine(
        text: String,
        configuration: LLMConfiguration,
        apiKey: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if let mock = ProcessInfo.processInfo.environment["VOICEINPUT_LLM_MOCK"], !mock.isEmpty {
            return try await refineWithMock(mock, text: text, timeoutSeconds: configuration.timeoutSeconds, onToken: onToken)
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMRefinerError.missingAPIKey
        }

        guard let url = URL(string: configuration.apiBaseURL)?
            .appendingPathComponent("chat")
            .appendingPathComponent("completions") else {
            throw LLMRefinerError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(configuration.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "messages": [
                [
                    "role": "system",
                    "content": configuration.systemPrompt,
                ],
                [
                    "role": "user",
                    "content": text,
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        log.notice("LLM request started baseURL=\(configuration.apiBaseURL) model=\(configuration.model) timeout=\(configuration.timeoutSeconds)s")

        let session = URLSession(configuration: .ephemeral)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMRefinerError.invalidResponse
            }

            if !(200...299).contains(httpResponse.statusCode) {
                var bodyData = Data()
                for try await byte in bytes {
                    bodyData.append(byte)
                    if bodyData.count >= 32_768 {
                        break
                    }
                }
                let body = String(data: bodyData, encoding: .utf8) ?? ""
                log.error("LLM HTTP error status=\(httpResponse.statusCode) body=\(body)")
                throw LLMRefinerError.httpError(statusCode: httpResponse.statusCode, body: body)
            }

            var accumulated = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String else {
                    continue
                }

                accumulated += content
                onToken(accumulated)
            }

            if accumulated.isEmpty {
                log.error("LLM returned empty stream")
                throw LLMRefinerError.invalidResponse
            }

            log.notice("LLM request finished outputLength=\(accumulated.count)")
            return accumulated
        } catch let error as LLMRefinerError {
            throw error
        } catch {
            let nsError = error as NSError
            log.error("LLM request failed domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                throw LLMRefinerError.timeout
            }
            if nsError.domain == NSURLErrorDomain {
                throw LLMRefinerError.unreachable
            }
            throw error
        }
    }

    func validate(configuration: LLMConfiguration, apiKey: String) async throws {
        if ProcessInfo.processInfo.environment["VOICEINPUT_LLM_VALIDATE_MOCK"] == "1" {
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMRefinerError.missingAPIKey
        }
        guard let url = URL(string: configuration.apiBaseURL)?
            .appendingPathComponent("models") else {
            throw LLMRefinerError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(configuration.timeoutSeconds)
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMRefinerError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMRefinerError.httpError(statusCode: httpResponse.statusCode, body: "")
        }
    }

    private func refineWithMock(
        _ mock: String,
        text: String,
        timeoutSeconds: Int,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        log.notice("LLM mock request started mode=\(mock)")
        if mock == "timeout" {
            try await Task.sleep(for: .seconds(timeoutSeconds + 1))
            log.error("LLM mock timeout")
            throw LLMRefinerError.timeout
        }
        if mock == "unreachable" {
            log.error("LLM mock unreachable")
            throw LLMRefinerError.unreachable
        }
        if mock.hasPrefix("http:") {
            let code = Int(mock.replacingOccurrences(of: "http:", with: "")) ?? 500
            log.error("LLM mock http error status=\(code)")
            throw LLMRefinerError.httpError(statusCode: code, body: "")
        }
        if mock == "passthrough" {
            onToken(text)
            log.notice("LLM mock passthrough outputLength=\(text.count)")
            return text
        }
        if mock.hasPrefix("streamdelay:") {
            let payload = String(mock.dropFirst("streamdelay:".count))
            let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
            let delayMs = Int(parts.first ?? "") ?? 250
            let tokens = parts.count > 1 ? parts[1].split(separator: "|").map(String.init) : []
            var accumulated = ""
            for token in tokens {
                try await Task.sleep(for: .milliseconds(delayMs))
                accumulated += token
                onToken(accumulated)
            }
            log.notice("LLM mock streamdelay finished outputLength=\(accumulated.count)")
            return accumulated
        }
        if mock.hasPrefix("stream:") {
            let payload = String(mock.dropFirst("stream:".count))
            let tokens = payload.split(separator: "|").map(String.init)
            var accumulated = ""
            for token in tokens {
                try await Task.sleep(for: .milliseconds(120))
                accumulated += token
                onToken(accumulated)
            }
            log.notice("LLM mock stream finished outputLength=\(accumulated.count)")
            return accumulated
        }
        throw LLMRefinerError.invalidResponse
    }
}
