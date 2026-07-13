import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live-server coverage for response-definition options that were golden-only:
/// custom status message, body-file, jsonBody content-type, multi-value response
/// headers, the random/chunked delays, and transformer parameters.
final class ResponseOptionsTests: XCTestCase {
    private var wireMock: WireMock!
    private var port: UInt16 { UInt16(WireMockFixture.baseURL.port ?? 8080) }

    override func setUp() async throws {
        wireMock = try await WireMockFixture.clientOrSkip()
    }

    override func tearDown() async throws {
        if wireMock != nil { try? await wireMock.resetAll() }
    }

    // MARK: withStatusMessage — observed on the wire (URLSession hides the phrase)

    func testStatusMessageOnTheWire() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/teapot")).willReturn(aResponse().withStatus(418).withStatusMessage("I am a teapot"))
        )
        let statusLine = try RawHTTP.statusLine(path: "/teapot", port: port)
        XCTAssertTrue(statusLine.contains("418"), "status line was: \(statusLine)")
        XCTAssertTrue(statusLine.contains("I am a teapot"),
                      "custom reason phrase missing from status line: \(statusLine)")
    }

    // MARK: multi-value response headers (multiple Set-Cookie)

    func testMultipleSetCookieHeadersOnTheWire() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/cookies")).willReturn(ok().withHeader("Set-Cookie", ["a=1", "b=2"]))
        )
        let cookies = try RawHTTP.headerValues("Set-Cookie", path: "/cookies", port: port)
        XCTAssertEqual(cookies.count, 2, "expected two distinct Set-Cookie headers, got: \(cookies)")
        XCTAssertTrue(cookies.contains("a=1"))
        XCTAssertTrue(cookies.contains("b=2"))
    }

    // MARK: withBodyFile

    func testBodyFileServed() async throws {
        try await wireMock.putFile(named: "resp.json", text: #"{"served":"from-file"}"#, contentType: "application/json")
        try await wireMock.stubFor(
            get(urlEqualTo("/bf")).willReturn(aResponse().withStatus(200).withBodyFile("resp.json"))
        )
        let (data, response) = try await WireMockFixture.hit("bf")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), ["served": "from-file"])
        try await wireMock.deleteFile(named: "resp.json")
    }

    // MARK: withJsonBody + content type

    func testJsonBodyContentType() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/jb")).willReturn(okForJson(["id": 7, "ok": true]))
        )
        let (data, response) = try await WireMockFixture.hit("jb")
        XCTAssertEqual(response.statusCode, 200)
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.contains("application/json"), "Content-Type was: \(contentType)")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), ["id": 7, "ok": true])
    }

    // MARK: withUniformRandomDelay (lifecycle + lower bound)

    func testUniformRandomDelayLifecycle() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/ud")).willReturn(ok("delayed").withUniformRandomDelay(lower: 300, upper: 500))
        )
        let start = Date()
        let (data, response) = try await WireMockFixture.hit("ud")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "delayed")
        // Uniform lower bound is 300ms; allow slack but require a real delay.
        XCTAssertGreaterThan(elapsed, 0.25, "uniform delay lower bound not honoured (elapsed \(elapsed)s)")
    }

    // MARK: withChunkedDribbleDelay (lifecycle + body intact + timing)

    func testChunkedDribbleDelayLifecycle() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/cd")).willReturn(ok("streamed-body").withChunkedDribbleDelay(numberOfChunks: 5, totalDuration: 400))
        )
        let start = Date()
        let (data, response) = try await WireMockFixture.hit("cd")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "streamed-body", "dribble must not corrupt the body")
        XCTAssertGreaterThan(elapsed, 0.3, "chunked dribble should spread the body over ~400ms (elapsed \(elapsed)s)")
    }

    // MARK: withTransformerParameter (consumed by response-template)

    func testTransformerParameter() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/tp")).willReturn(
                ok("greeting={{parameters.greeting}}")
                    .withTransformers("response-template")
                    .withTransformerParameter("greeting", "hello")
            )
        )
        let (data, _) = try await WireMockFixture.hit("tp")
        XCTAssertEqual(String(data: data, encoding: .utf8), "greeting=hello")
    }
}
