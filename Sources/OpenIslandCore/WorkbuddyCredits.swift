import Foundation

/// One pooled account's credit balance as reported by the workbuddy-manager
/// admin API (`/api/accounts`).
public struct WorkbuddyAccountCredits: Equatable, Codable, Sendable, Identifiable {
    public var uid: String
    public var nickname: String?
    public var credits: Int

    public var id: String { uid }

    public init(uid: String, nickname: String?, credits: Int) {
        self.uid = uid
        self.nickname = nickname
        self.credits = credits
    }
}

/// Cached snapshot of the workbuddy gateway's pooled-account credits.
public struct WorkbuddyCreditsSnapshot: Equatable, Codable, Sendable {
    public var accounts: [WorkbuddyAccountCredits]
    public var fetchedAt: Date

    public init(accounts: [WorkbuddyAccountCredits], fetchedAt: Date) {
        self.accounts = accounts
        self.fetchedAt = fetchedAt
    }

    public var totalCredits: Int {
        accounts.reduce(0) { $0 + $1.credits }
    }

    public var isEmpty: Bool {
        accounts.isEmpty
    }
}

/// Reads and writes the local credits cache shared between the fetch
/// coordinator and the island UI. The cache is a single JSON file so the
/// panel can render the last known total even while a refresh is in flight.
public enum WorkbuddyCreditsCache {
    public static let defaultCacheURL = URL(fileURLWithPath: "/tmp/open-island-wb-credits.json")

    public static func load(url: URL = defaultCacheURL) -> WorkbuddyCreditsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkbuddyCreditsSnapshot.self, from: data)
    }

    public static func save(_ snapshot: WorkbuddyCreditsSnapshot, url: URL = defaultCacheURL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func remove(url: URL = defaultCacheURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Fetches pooled-account credits from a workbuddy-manager admin API and
/// persists them to the local cache. Auth uses the admin session cookie
/// obtained by `POST /api/login`; the password comes from the caller (the app
/// reads it from the macOS keychain).
public enum WorkbuddyCreditsFetcher {
    /// Shape of `GET /api/accounts` (subset of fields we consume).
    private struct AccountsResponse: Decodable {
        struct Account: Decodable {
            var uid: String
            var nickname: String?
            var credits: Int?
        }

        var accounts: [Account]
    }

    public struct Configuration: Equatable, Sendable {
        public var baseURL: URL
        public var username: String

        public init(baseURL: URL, username: String = "admin") {
            self.baseURL = baseURL
            self.username = username
        }
    }

    public enum FetchError: Error, Equatable {
        case loginFailed(status: Int)
        case accountsFailed(status: Int)
        case malformedResponse
    }

    public static func fetch(
        configuration: Configuration,
        password: String,
        session: URLSession = .shared,
        cacheURL: URL = WorkbuddyCreditsCache.defaultCacheURL
    ) async throws -> WorkbuddyCreditsSnapshot {
        var loginRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/login"))
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.httpBody = try JSONEncoder().encode([
            "username": configuration.username,
            "password": password,
        ])

        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        guard let httpResponse = loginResponse as? HTTPURLResponse else {
            throw FetchError.loginFailed(status: -1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FetchError.loginFailed(status: httpResponse.statusCode)
        }
        guard let loginPayload = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
              loginPayload["ok"] as? Bool == true else {
            throw FetchError.malformedResponse
        }

        guard let cookie = HTTPCookieStorage.shared.cookies?
            .first(where: { $0.domain.contains(configuration.baseURL.host ?? "") }) else {
            throw FetchError.malformedResponse
        }

        var accountsRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/accounts"))
        accountsRequest.httpMethod = "GET"
        accountsRequest.setValue(cookie.name + "=" + cookie.value, forHTTPHeaderField: "Cookie")

        let (accountsData, accountsResponse) = try await session.data(for: accountsRequest)
        guard let accountsHttpResponse = accountsResponse as? HTTPURLResponse else {
            throw FetchError.accountsFailed(status: -1)
        }
        guard (200..<300).contains(accountsHttpResponse.statusCode) else {
            throw FetchError.accountsFailed(status: accountsHttpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(AccountsResponse.self, from: accountsData)
        let accounts = decoded.accounts.map {
            WorkbuddyAccountCredits(
                uid: $0.uid,
                nickname: $0.nickname,
                credits: $0.credits ?? 0
            )
        }
        let snapshot = WorkbuddyCreditsSnapshot(accounts: accounts, fetchedAt: Date())
        WorkbuddyCreditsCache.save(snapshot, url: cacheURL)
        return snapshot
    }
}
