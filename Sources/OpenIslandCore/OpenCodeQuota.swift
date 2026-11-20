import Foundation

/// One OpenCode Go (Zen) quota window as reported by
/// `GET https://opencode.ai/zen/go/v1/usage`.
public struct OpenCodeQuotaWindow: Equatable, Codable, Sendable, Identifiable {
    /// `rolling`, `weekly`, or `monthly`.
    public var key: String
    /// Percentage of the quota still available (0–100).
    public var percentRemaining: Double
    public var resetsAt: Date?
    /// True when the API reports the window as `rate-limited` (quota
    /// exhausted); the window then renders as fully used.
    public var rateLimited: Bool

    public var id: String { key }

    public init(
        key: String,
        percentRemaining: Double,
        resetsAt: Date?,
        rateLimited: Bool = false
    ) {
        self.key = key
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
        self.rateLimited = rateLimited
    }

    /// Percentage of the quota already consumed, for the percent-based usage
    /// chips (mirrors the Claude/Codex convention).
    public var usedPercentage: Double {
        rateLimited ? 100 : (100 - percentRemaining)
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

/// Snapshot of the OpenCode Go usage windows. Only the windows the chip lane
/// renders (`rolling`, `weekly`) are kept, in display order.
public struct OpenCodeQuotaSnapshot: Equatable, Codable, Sendable {
    public var windows: [OpenCodeQuotaWindow]
    public var fetchedAt: Date

    public init(windows: [OpenCodeQuotaWindow], fetchedAt: Date) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool {
        windows.isEmpty
    }
}

/// Reads and writes the local quota cache shared between the fetch
/// coordinator and the island UI, so the panel can render the last known
/// quota even while a refresh is in flight.
public enum OpenCodeQuotaCache {
    public static let defaultCacheURL = URL(fileURLWithPath: "/tmp/open-island-opencode-quota.json")

    public static func load(url: URL = defaultCacheURL) -> OpenCodeQuotaSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OpenCodeQuotaSnapshot.self, from: data)
    }

    public static func save(_ snapshot: OpenCodeQuotaSnapshot, url: URL = defaultCacheURL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func remove(url: URL = defaultCacheURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Reads the OpenCode Go API key from the opencode CLI's auth store
/// (`~/.local/share/opencode/auth.json`). The preferred provider id is
/// `opencode-go`, falling back to `opencode` when the former is absent.
/// The key is never logged or persisted beyond the in-flight request.
public enum OpenCodeAuthKey {
    public static let defaultAuthURL = URL(
        fileURLWithPath: NSString(string: "~/.local/share/opencode/auth.json").expandingTildeInPath
    )

    private struct AuthEntry: Decodable {
        var type: String?
        var key: String?
    }

    private typealias AuthStore = [String: AuthEntry]

    public static func read(url: URL = defaultAuthURL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let store = try? JSONDecoder().decode(AuthStore.self, from: data) else { return nil }
        let key = store["opencode-go"]?.key ?? store["opencode"]?.key
        guard let key, key.isEmpty == false else { return nil }
        return key
    }
}

/// Fetches OpenCode Go quota windows and persists them to the local cache.
public enum OpenCodeQuotaFetcher {
    /// Shape of `GET /zen/go/v1/usage` (subset of fields we consume; the
    /// `percent` field is the percentage already *used* within the window).
    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            var status: String
            var percent: Double?
            var resetsAt: String
        }

        var usage: UsageWindows
    }

    private struct UsageWindows: Decodable {
        var rolling: UsageResponse.Window?
        var weekly: UsageResponse.Window?
        var monthly: UsageResponse.Window?
    }

    public struct Configuration: Equatable, Sendable {
        public var endpoint: URL

        public init(endpoint: URL = URL(string: "https://opencode.ai/zen/go/v1/usage")!) {
            self.endpoint = endpoint
        }
    }

    public enum FetchError: Error, Equatable {
        case missingAPIKey
        case requestFailed(status: Int)
        case malformedResponse
    }

    private static func parseResetsAt(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    public static func fetch(
        configuration: Configuration = Configuration(),
        apiKey: String?,
        session: URLSession = .shared,
        cacheURL: URL = OpenCodeQuotaCache.defaultCacheURL
    ) async throws -> OpenCodeQuotaSnapshot {
        guard let apiKey, apiKey.isEmpty == false else {
            throw FetchError.missingAPIKey
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.requestFailed(status: -1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FetchError.requestFailed(status: httpResponse.statusCode)
        }

        let decoded: UsageResponse
        do {
            decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw FetchError.malformedResponse
        }

        func makeWindow(key: String, window: UsageResponse.Window?) -> OpenCodeQuotaWindow? {
            guard let window else { return nil }
            guard window.status == "ok" || window.status == "rate-limited" else { return nil }
            guard let percent = window.percent,
                  percent.isFinite, percent >= 0, percent <= 100 else { return nil }
            let rateLimited = window.status == "rate-limited"
            return OpenCodeQuotaWindow(
                key: key,
                percentRemaining: rateLimited ? 0 : (100 - percent),
                resetsAt: parseResetsAt(window.resetsAt),
                rateLimited: rateLimited
            )
        }

        let windows = [
            makeWindow(key: "rolling", window: decoded.usage.rolling),
            makeWindow(key: "weekly", window: decoded.usage.weekly),
        ].compactMap { $0 }

        guard windows.isEmpty == false else {
            throw FetchError.malformedResponse
        }

        let snapshot = OpenCodeQuotaSnapshot(windows: windows, fetchedAt: Date())
        OpenCodeQuotaCache.save(snapshot, url: cacheURL)
        return snapshot
    }
}
