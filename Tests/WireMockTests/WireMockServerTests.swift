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
}
#endif
