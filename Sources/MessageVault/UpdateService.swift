import Foundation

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease
        case htmlURL = "html_url"
    }
}

enum UpdateResult: Sendable {
    case available(GitHubRelease)
    case upToDate(GitHubRelease)
}

struct UpdateService: Sendable {
    static let repositoryURL = URL(string: "https://github.com/ScottPhillips/MessageVault")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/ScottPhillips/MessageVault/releases/latest")!

    func check(currentVersion: String) async throws -> UpdateResult {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MessageVault/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MessageVaultError.update("GitHub returned status \(code).")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return .upToDate(release) }
        return Self.isNewer(release.tagName, than: currentVersion) ? .available(release) : .upToDate(release)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate), rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in Int(component.prefix(while: \.isNumber)) ?? 0 }
    }
}

extension MessageVaultError {
    static func update(_ message: String) -> MessageVaultError { .export("Update check failed: \(message)") }
}
