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
        // resetAll() clears mappings and the journal but NOT a leaked global
        // delay distribution or an in-progress recording, so establish a truly
        // clean baseline here rather than trusting the previous suite's tearDown.
        try? wireMock.setGlobalFixedDelay(0)
        _ = try? wireMock.stopRecording()
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

// MARK: - Shared test assertions / codecs

extension WireMockFixture {
    /// Decodes JSON text into a `Decodable` (shared by the pure-decode suites).
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Encodes an `Encodable` to JSON text.
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// Asserts a request matched a stub (HTTP 200). Forwards `file`/`line` so a
    /// failure points at the call site, not this helper.
    static func assertMatch(
        _ result: (Data, HTTPURLResponse), _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.1.statusCode, 200, "expected match. \(message)", file: file, line: line)
    }

    /// Asserts a request matched no stub (HTTP 404).
    static func assertMiss(
        _ result: (Data, HTTPURLResponse), _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.1.statusCode, 404, "expected no match. \(message)", file: file, line: line)
    }

    /// Runs `body` and asserts it took at least `minSeconds`. A **lower** bound
    /// only — extra load can only make it slower, so this never flakes upward.
    @discardableResult
    static func assertTakesAtLeast<T>(
        _ minSeconds: TimeInterval, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) rethrows -> T {
        let start = Date()
        let result = try body()
        XCTAssertGreaterThan(Date().timeIntervalSince(start), minSeconds, message, file: file, line: line)
        return result
    }
}

// MARK: - Base case for live-server suites

/// Base class for integration suites that need a live WireMock server.
///
/// Provides a reset `wireMock` client in `setUp` (honouring the skip-vs-fail
/// policy via `WIREMOCK_REQUIRED`) and a **superset** cleanup in `tearDown`, so
/// individual suites no longer redeclare the same lifecycle — and can't drift in
/// what they reset. `resetAll()` alone clears neither a global delay nor an
/// in-progress recording, so both are neutralized here as well.
///
/// - Important: these suites share one server and reset it in `setUp`; they are
///   **not** parallel-safe. Run serially (the default `swift test`).
class WireMockIntegrationCase: XCTestCase {
    /// A freshly reset client for the shared server. Force-unwrapped because
    /// `setUp` either assigns it or skips/fails the test before any body runs.
    var wireMock: WireMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        wireMock = try WireMockFixture.clientOrSkip()
    }

    override func tearDownWithError() throws {
        if wireMock != nil {
            try? wireMock.setGlobalFixedDelay(0)
            _ = try? wireMock.stopRecording()
            try? wireMock.resetAll()
        }
        wireMock = nil
        try super.tearDownWithError()
    }
}
