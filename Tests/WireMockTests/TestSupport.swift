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
    static func clientOrSkip() throws -> WireMock {
        let wireMock = WireMock(baseURL: baseURL)
        do {
            _ = try wireMock.listAllStubMappings()
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
        try wireMock.resetAll()
        return wireMock
    }

    /// Sends a plain HTTP request to the mock server (not the admin API).
    @discardableResult
    static func hit(
        _ path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> (Data, HTTPURLResponse) {
        // Build the URL by concatenation so a query string in `path` is
        // preserved (appendingPathComponent would percent-encode "?").
        let url = URL(string: baseURL.absoluteString + "/" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return try syncData(for: request)
    }

    /// Synchronous `URLSession` request (blocks until the response arrives on
    /// URLSession's own queue). Mirrors the library's synchronous transport so
    /// the tests read the same way the client does.
    @discardableResult
    static func syncData(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        final class Holder: @unchecked Sendable { var result: Result<(Data, URLResponse), Error>? }
        let holder = Holder()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                holder.result = .failure(error)
            } else if let data, let response {
                holder.result = .success((data, response))
            } else {
                holder.result = .failure(WireMockError.transport(underlying: "No data and no error"))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        switch holder.result {
        case .success(let (data, response)):
            guard let http = response as? HTTPURLResponse else {
                throw WireMockError.transport(underlying: "Expected an HTTP response, got \(type(of: response))")
            }
            return (data, http)
        case .failure(let error): throw error
        case nil: throw WireMockError.transport(underlying: "Request produced no result")
        }
    }
}
