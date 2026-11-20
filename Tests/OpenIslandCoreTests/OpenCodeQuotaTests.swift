import Foundation
import Testing
@testable import OpenIslandCore

/// Stubs `URLSession` traffic for `OpenCodeQuotaFetcher` tests.
private final class QuotaURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastAuthorizationHeader: String?
    nonisolated(unsafe) static var lastAcceptHeader: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.lastAcceptHeader = request.value(forHTTPHeaderField: "Accept")
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Raw shape of `GET https://opencode.ai/zen/go/v1/usage`, modeled on the
/// `@slkiser/opencode-quota` plugin's decoder: `usage.<window>` carries
/// `status` ("ok" | "rate-limited"), `percent` (already used, 0–100) and
/// `resetsAt` (offset-qualified ISO timestamp).
private let rawUsageFixture = """
{
  "usage": {
    "rolling": {
      "status": "ok",
      "percent": 42.5,
      "resetsAt": "2026-11-20T12:34:56Z"
    },
    "weekly": {
      "status": "ok",
      "percent": 10,
      "resetsAt": "2026-11-23T00:00:00.000Z"
    },
    "monthly": {
      "status": "rate-limited",
      "percent": 100,
      "resetsAt": "2026-11-30T00:00:00+08:00"
    }
  }
}
"""

@Suite(.serialized)
struct OpenCodeQuotaTests {

    private func makeTempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-opencode-quota-\(UUID().uuidString).json")
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAuthFixtureURL(opencodeGoKey: String?, opencodeKey: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        var store: [String: Any] = [:]
        if let opencodeGoKey {
            store["opencode-go"] = ["type": "api", "key": opencodeGoKey]
        }
        if let opencodeKey {
            store["opencode"] = ["type": "api", "key": opencodeKey]
        }
        try JSONSerialization.data(withJSONObject: store).write(to: url)
        return url
    }

    @Test
    func fetchDecodesRawUsageResponse() async throws {
        let cacheURL = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        QuotaURLProtocol.handler = { _ in (200, Data(rawUsageFixture.utf8)) }
        defer { QuotaURLProtocol.handler = nil }
        QuotaURLProtocol.lastAuthorizationHeader = nil
        defer {
            QuotaURLProtocol.lastAuthorizationHeader = nil
            QuotaURLProtocol.lastAcceptHeader = nil
        }

        let snapshot = try await OpenCodeQuotaFetcher.fetch(
            configuration: .init(endpoint: URL(string: "https://example.test/usage")!),
            apiKey: "sk-test-key",
            session: makeStubbedSession(),
            cacheURL: cacheURL
        )

        // Only the chip-lane windows (rolling, weekly) are kept, in order.
        #expect(snapshot.windows.map { $0.key } == ["rolling", "weekly"])

        let rolling = snapshot.windows[0]
        #expect(rolling.percentRemaining == 57.5)
        #expect(rolling.usedPercentage == 42.5)
        #expect(rolling.rateLimited == false)
        #expect(rolling.resetsAt == Date(timeIntervalSince1970: 1_795_178_096)) // 2026-11-20T12:34:56Z

        let weekly = snapshot.windows[1]
        #expect(weekly.percentRemaining == 90)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_795_392_000)) // 2026-11-23T00:00:00Z

        // The API key is sent as a bearer token, never echoed elsewhere.
        #expect(QuotaURLProtocol.lastAuthorizationHeader == "Bearer sk-test-key")
        #expect(QuotaURLProtocol.lastAcceptHeader == "application/json")

        // A successful fetch persists the snapshot to the cache.
        #expect(OpenCodeQuotaCache.load(url: cacheURL) == snapshot)
    }

    @Test
    func fetchMapsRateLimitedWindowToFullyUsed() async throws {
        let rateLimitedFixture = """
        {"usage":{"rolling":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-20T12:00:00Z"},
        "weekly":{"status":"ok","percent":0,"resetsAt":"2026-11-23T00:00:00Z"}}}
        """
        QuotaURLProtocol.handler = { _ in (200, Data(rateLimitedFixture.utf8)) }
        defer { QuotaURLProtocol.handler = nil }

        let snapshot = try await OpenCodeQuotaFetcher.fetch(
            configuration: .init(endpoint: URL(string: "https://example.test/usage")!),
            apiKey: "sk-test-key",
            session: makeStubbedSession(),
            cacheURL: makeTempCacheURL()
        )

        let rolling = snapshot.windows[0]
        #expect(rolling.rateLimited == true)
        #expect(rolling.percentRemaining == 0)
        #expect(rolling.usedPercentage == 100)

        // percentRemaining 100 (nothing used) maps to usedPercentage 0.
        let weekly = snapshot.windows[1]
        #expect(weekly.percentRemaining == 100)
        #expect(weekly.usedPercentage == 0)
    }

    @Test
    func fetchThrowsWithoutAPIKey() async {
        do {
            _ = try await OpenCodeQuotaFetcher.fetch(
                apiKey: nil,
                session: makeStubbedSession(),
                cacheURL: makeTempCacheURL()
            )
            Issue.record("expected missingAPIKey")
        } catch let error as OpenCodeQuotaFetcher.FetchError {
            #expect(error == .missingAPIKey)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func fetchThrowsOnHTTPError() async {
        QuotaURLProtocol.handler = { _ in
            (401, Data(#"{"type":"error","error":{"type":"api_key_expired"}}"#.utf8))
        }
        defer { QuotaURLProtocol.handler = nil }

        await #expect(throws: OpenCodeQuotaFetcher.FetchError.requestFailed(status: 401)) {
            try await OpenCodeQuotaFetcher.fetch(
                apiKey: "sk-expired",
                session: makeStubbedSession(),
                cacheURL: makeTempCacheURL()
            )
        }
    }

    @Test
    func fetchThrowsOnMalformedBody() async {
        QuotaURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        defer { QuotaURLProtocol.handler = nil }

        await #expect(throws: OpenCodeQuotaFetcher.FetchError.malformedResponse) {
            try await OpenCodeQuotaFetcher.fetch(
                apiKey: "sk-test-key",
                session: makeStubbedSession(),
                cacheURL: makeTempCacheURL()
            )
        }
    }

    @Test
    func authKeyPrefersOpenCodeGoAndFallsBack() throws {
        let both = try makeAuthFixtureURL(opencodeGoKey: "sk-go-key", opencodeKey: "sk-fallback")
        defer { try? FileManager.default.removeItem(at: both) }
        #expect(OpenCodeAuthKey.read(url: both) == "sk-go-key")

        let fallbackOnly = try makeAuthFixtureURL(opencodeGoKey: nil, opencodeKey: "sk-fallback")
        defer { try? FileManager.default.removeItem(at: fallbackOnly) }
        #expect(OpenCodeAuthKey.read(url: fallbackOnly) == "sk-fallback")

        let neither = try makeAuthFixtureURL(opencodeGoKey: nil, opencodeKey: nil)
        defer { try? FileManager.default.removeItem(at: neither) }
        #expect(OpenCodeAuthKey.read(url: neither) == nil)

        #expect(OpenCodeAuthKey.read(url: makeTempCacheURL()) == nil)
    }

    @Test
    func cacheRoundTripsSnapshot() throws {
        let url = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = OpenCodeQuotaSnapshot(
            windows: [
                OpenCodeQuotaWindow(
                    key: "rolling",
                    percentRemaining: 80,
                    resetsAt: Date(timeIntervalSince1970: 1_760_036_000),
                    rateLimited: false
                ),
                OpenCodeQuotaWindow(
                    key: "weekly",
                    percentRemaining: 45.5,
                    resetsAt: nil,
                    rateLimited: true
                ),
            ],
            fetchedAt: fetchedAt
        )

        OpenCodeQuotaCache.save(snapshot, url: url)

        let loaded = OpenCodeQuotaCache.load(url: url)
        #expect(loaded == snapshot)
        #expect(loaded?.windows.first?.roundedUsedPercentage == 20)
    }

    @Test
    func cacheLoadReturnsNilForMissingFile() {
        #expect(OpenCodeQuotaCache.load(url: makeTempCacheURL()) == nil)
    }

    @Test
    func cacheRemoveDeletesFile() throws {
        let url = makeTempCacheURL()
        OpenCodeQuotaCache.save(
            OpenCodeQuotaSnapshot(windows: [], fetchedAt: Date()),
            url: url
        )
        OpenCodeQuotaCache.remove(url: url)
        #expect(OpenCodeQuotaCache.load(url: url) == nil)
    }

    @Test
    func snapshotEmptyWhenNoWindows() {
        let empty = OpenCodeQuotaSnapshot(windows: [], fetchedAt: Date())
        #expect(empty.isEmpty)
    }
}
