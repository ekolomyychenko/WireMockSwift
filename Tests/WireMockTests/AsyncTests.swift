import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Covers `wireMock.callAsync { }` — the optional bridge for reaching the
/// (synchronous-by-design) client from an `async` context.
final class AsyncTests: XCTestCase {

    private let wireMock = WireMock(baseURL: URL(string: "http://stub.local:8080")!)

    override func tearDownWithError() throws {
        // The live test registers a stub on the shared server; reset it so the
        // suite doesn't leak state (it can't reuse the stub.local client above).
        try? WireMock(baseURL: WireMockFixture.baseURL).resetAll()
    }

    func testCallAsyncReturnsValue() async throws {
        let value = try await wireMock.callAsync { _ in 42 }
        XCTAssertEqual(value, 42)
    }

    func testCallAsyncPropagatesError() async {
        struct Boom: Error {}
        do {
            _ = try await wireMock.callAsync { _ in throw Boom() }
            XCTFail("error should propagate out of callAsync")
        } catch {
            XCTAssertTrue(error is Boom, "underlying error must propagate, got \(error)")
        }
    }

    func testCallAsyncPassesTheClient() async throws {
        // The closure receives the same client (so `$0.` reads naturally).
        let baseURL = try await wireMock.callAsync { $0.admin.baseURL.absoluteString }
        XCTAssertEqual(baseURL, "http://stub.local:8080")
    }

    /// Live-server smoke test: drive a real stub+verify from an async context.
    func testCallAsyncStubAndVerifyLive() async throws {
        let client = try WireMockFixture.clientOrSkip()
        try await client.callAsync { _ = try $0.stubFor(get(urlEqualTo("/async")).willReturn(ok("ok"))) }
        // Pin the served response: a stub that never registered (404) or a wrong
        // body would otherwise pass, since verify alone can't prove it served.
        let (data, response) = try WireMockFixture.hit("async")
        XCTAssertEqual(response.statusCode, 200, "stub must have registered and served through the async bridge")
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        try await client.callAsync { try $0.verify(getRequestedFor(urlEqualTo("/async"))) }
    }
}
