import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared helpers for integration tests that need a live WireMock server.
///
/// - Important: The integration suites share one server and each `setUp` calls
///   `resetAll()`, so they are **not** parallel-safe. Run `swift test` serially
///   (the default); do not enable `--parallel` without per-suite server isolation.
enum WireMockFixture {
    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["WIREMOCK_URL"] ?? "http://localhost:8080")!
    }

    /// Returns a client for a running server, resetting it first, or throws
    /// `XCTSkip` if none is reachable.
    static func clientOrSkip() async throws -> WireMock {
        let wireMock = WireMock(baseURL: baseURL)
        do {
            _ = try await wireMock.listAllStubMappings()
        } catch {
            // In CI we set WIREMOCK_REQUIRED=1 so a missing/unhealthy server
            // FAILS the build instead of silently skipping (a skip-storm must
            // never masquerade as a green run).
            if ProcessInfo.processInfo.environment["WIREMOCK_REQUIRED"] == "1" {
                XCTFail("WIREMOCK_REQUIRED=1 but no server reachable at \(baseURL): \(error)")
                throw error
            }
            throw XCTSkip("No WireMock server reachable at \(baseURL): \(error)")
        }
        try await wireMock.resetAll()
        return wireMock
    }

    /// Sends a plain HTTP request to the mock server (not the admin API).
    @discardableResult
    static func hit(
        _ path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        // Build the URL by concatenation so a query string in `path` is
        // preserved (appendingPathComponent would percent-encode "?").
        let url = URL(string: baseURL.absoluteString + "/" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WireMockError.transport(underlying: "Expected an HTTP response, got \(type(of: response))")
        }
        return (data, http)
    }
}
