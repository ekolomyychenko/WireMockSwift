import XCTest
@testable import WireMock

/// End-to-end coverage of admin-API Basic auth against a server that actually
/// enforces it (`--admin-api-basic-auth`). `ClientUnitTests` proves the
/// `Authorization` header is *attached*; this proves the server *rejects*
/// without it and *accepts* with it — the one security-relevant behaviour that
/// a header-attachment unit test can't demonstrate.
///
/// Gated on `WIREMOCK_AUTH_URL` (+ `WIREMOCK_AUTH_CREDS`), which point at a
/// second WireMock instance started with auth on a separate port:
///
///   WIREMOCK_PORT=8090 WIREMOCK_ADMIN_AUTH=wmadmin:wmsecret \
///   WIREMOCK_PID_FILE=.wiremock-auth.pid Scripts/start-wiremock.sh
///   WIREMOCK_AUTH_URL=http://localhost:8090 WIREMOCK_AUTH_CREDS=wmadmin:wmsecret swift test
///
/// The suite XCTSkips when that instance isn't configured, so the default
/// single-server `swift test` stays green without it.
final class AdminAuthIntegrationTests: XCTestCase {
    private struct AuthConfig { let url: URL; let user: String; let pass: String }

    private func authConfigOrSkip() throws -> AuthConfig {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["WIREMOCK_AUTH_URL"], let url = URL(string: urlString),
              let creds = env["WIREMOCK_AUTH_CREDS"] else {
            throw XCTSkip("Set WIREMOCK_AUTH_URL + WIREMOCK_AUTH_CREDS to a WireMock started with --admin-api-basic-auth")
        }
        let parts = creds.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw XCTSkip("WIREMOCK_AUTH_CREDS must be in 'user:pass' form")
        }
        return AuthConfig(url: url, user: parts[0], pass: parts[1])
    }

    private func assertUnauthorized(
        _ error: Error, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case WireMockError.unexpectedStatus(let code, _) = error else {
            return XCTFail("expected WireMockError.unexpectedStatus(401), got \(error)", file: file, line: line)
        }
        XCTAssertEqual(code, 401, "admin API should reject the request", file: file, line: line)
    }

    func testAdminApiRejectsMissingCredentials() throws {
        let cfg = try authConfigOrSkip()
        let client = WireMock(baseURL: cfg.url) // no authorization
        XCTAssertThrowsError(try client.listAllStubMappings()) { assertUnauthorized($0) }
    }

    func testAdminApiRejectsWrongCredentials() throws {
        let cfg = try authConfigOrSkip()
        let client = WireMock(baseURL: cfg.url,
                              authorization: .basic(username: cfg.user, password: cfg.pass + "-wrong"))
        XCTAssertThrowsError(try client.listAllStubMappings()) { assertUnauthorized($0) }
    }

    func testAdminApiAcceptsValidCredentials() throws {
        let cfg = try authConfigOrSkip()
        let client = WireMock(baseURL: cfg.url,
                              authorization: .basic(username: cfg.user, password: cfg.pass))
        // A full round-trip: reset, register a stub, read it back — all through
        // the authorized admin API, proving the credentials unlock every verb.
        try client.resetAll()
        try client.stubFor(get(urlEqualTo("/authed")).willReturn(ok("hi")))
        XCTAssertEqual(try client.listAllStubMappings().count, 1)
        try client.resetAll()
    }
}
