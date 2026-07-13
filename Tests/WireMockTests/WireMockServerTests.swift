import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
/// Verifies that `WireMockServer` can boot a real server from code and drive it.
///
/// Requires the standalone jar; set `WIREMOCK_JAR=/path/to/wiremock-standalone.jar`.
/// Skips otherwise. (Docker mode is exercised the same way via a `.docker` launch
/// when a daemon is available.)
final class WireMockServerTests: XCTestCase {
    func testStartStubAndStop() async throws {
        guard let jar = ProcessInfo.processInfo.environment["WIREMOCK_JAR"] else {
            throw XCTSkip("Set WIREMOCK_JAR to the standalone jar path to run this test")
        }

        let port = Int(ProcessInfo.processInfo.environment["WIREMOCK_TEST_PORT"] ?? "") ?? 8085
        let server = WireMockServer(port: port, launch: .jar(path: jar))
        try await server.start(timeout: 60)
        defer { server.stop() }

        let client = server.client
        try await client.stubFor(get(urlEqualTo("/booted")).willReturn(ok("up")))

        let url = URL(string: "http://localhost:\(port)/booted")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "up")
    }

    /// `start()` must refuse a port already served by another/stale server
    /// rather than silently attaching to it and orphaning its own process.
    func testStartOnOccupiedPortThrows() async throws {
        guard let jar = ProcessInfo.processInfo.environment["WIREMOCK_JAR"] else {
            throw XCTSkip("Set WIREMOCK_JAR to the standalone jar path to run this test")
        }
        let port = 8086
        let first = WireMockServer(port: port, launch: .jar(path: jar))
        try await first.start(timeout: 60)
        defer { first.stop() }

        let second = WireMockServer(port: port, launch: .jar(path: jar))
        do {
            try await second.start(timeout: 10)
            second.stop()
            XCTFail("start() should refuse an already-occupied port, not attach to the foreign server")
        } catch {
            // Expected: refused rather than attaching to the foreign server.
        }
    }

    /// A server secured with `--admin-api-basic-auth` rejects unauthenticated
    /// clients and accepts a client configured with matching credentials.
    func testSecuredAdminApiRequiresAuth() async throws {
        guard let jar = ProcessInfo.processInfo.environment["WIREMOCK_JAR"] else {
            throw XCTSkip("Set WIREMOCK_JAR to the standalone jar path to run this test")
        }
        let port = 8093
        let server = WireMockServer(
            port: port,
            launch: .jar(path: jar, extraArgs: ["--admin-api-basic-auth", "admin:s3cret"])
        )
        try await server.start(timeout: 60)
        defer { server.stop() }
        let base = server.baseURL

        // Without credentials the admin API returns 401.
        let noAuth = WireMock(baseURL: base)
        do {
            _ = try await noAuth.listAllStubMappings()
            XCTFail("expected 401 without credentials")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 401)
        }

        // With matching credentials it works.
        let authed = WireMock(baseURL: base, authorization: .basic(username: "admin", password: "s3cret"))
        try await authed.resetAll()
        try await authed.stubFor(get(urlEqualTo("/ok")).willReturn(ok()))
        let stubs = try await authed.listAllStubMappings()
        XCTAssertTrue(stubs.contains { $0.request.url == "/ok" })
    }
}
#endif
