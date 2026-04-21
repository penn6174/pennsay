import Foundation

struct ReleaseInfo: Sendable {
    let version: String
    let build: Int?
    let tag: String
    let releaseNotes: String
    let htmlURL: URL
    let zipAssetURL: URL?
}

enum UpdateCheckResult: Sendable {
    case updateAvailable(ReleaseInfo)
    case upToDate(currentVersion: String)
}

enum UpdateCheckError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "更新地址无效"
        case .invalidResponse:
            return "更新响应无效"
        case let .httpError(statusCode):
            return "更新检查失败 HTTP \(statusCode)"
        }
    }
}

struct UpdateChecker {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let body: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    static func checkLatest() async throws -> UpdateCheckResult {
        let owner = ProcessInfo.processInfo.environment["VOICEINPUT_GITHUB_OWNER"] ?? AppEnvironment.githubRepoOwner
        let repo = ProcessInfo.processInfo.environment["VOICEINPUT_GITHUB_REPO"] ?? AppEnvironment.githubRepoName
        let feed = ProcessInfo.processInfo.environment["VOICEINPUT_UPDATE_FEED_URL"]
            ?? "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"

        guard let url = URL(string: feed) else {
            throw UpdateCheckError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let release = try decoder.decode(GitHubRelease.self, from: data)
        let currentVersion = ProcessInfo.processInfo.environment["VOICEINPUT_CURRENT_VERSION"]
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        let currentBuild = Int(
            (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        ) ?? 0
        let tag = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let current = Version(currentVersion)
        let remote = Version(tag)
        let remoteBuild = parseBuildFromBody(release.body)

        // Update if remote version is strictly newer,
        // or same version but a larger build number is declared in release body.
        let shouldUpdate: Bool
        if remote > current {
            shouldUpdate = true
        } else if currentVersion == tag, let rb = remoteBuild, rb > currentBuild {
            shouldUpdate = true
        } else {
            shouldUpdate = false
        }

        if shouldUpdate {
            let zipAssetURL = release.assets.first { asset in
                asset.name.hasSuffix(".zip")
            }?.browserDownloadURL
            return .updateAvailable(
                ReleaseInfo(
                    version: tag,
                    build: remoteBuild,
                    tag: release.tagName,
                    releaseNotes: release.body,
                    htmlURL: release.htmlURL,
                    zipAssetURL: zipAssetURL
                )
            )
        }

        return .upToDate(currentVersion: currentVersion)
    }

    /// Parse the build number from a release body that contains a line like
    /// `Build: 2` or `build 2`. Returns nil if no build marker found.
    private static func parseBuildFromBody(_ body: String) -> Int? {
        let patterns = [
            #"(?i)\bbuild[:\s]+(\d+)\b"#,
            #"(?i)\bbuild\s*#\s*(\d+)\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if let match = regex.firstMatch(in: body, range: range),
               match.numberOfRanges >= 2,
               let numberRange = Range(match.range(at: 1), in: body),
               let number = Int(body[numberRange]) {
                return number
            }
        }
        return nil
    }
}
