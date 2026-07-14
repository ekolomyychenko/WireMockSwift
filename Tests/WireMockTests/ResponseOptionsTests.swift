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
    private var host: String { WireMockFixture.baseURL.host ?? "127.0.0.1" }

    override func setUpWithError() throws {
        wireMock = try WireMockFixture.clientOrSkip()
    }

    override func tearDownWithError() throws {
        if wireMock != nil { try? wireMock.resetAll() }
    }

    // MARK: withStatusMessage — observed on the wire (URLSession hides the phrase)

    func testStatusMessageOnTheWire() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/teapot")).willReturn(aResponse().withStatus(418).withStatusMessage("I am a teapot"))
        )
        let statusLine = try RawHTTP.statusLine(path: "/teapot", host: host, port: port)
        XCTAssertTrue(statusLine.contains("418"), "status line was: \(statusLine)")
        XCTAssertTrue(statusLine.contains("I am a teapot"),
                      "custom reason phrase missing from status line: \(statusLine)")
    }

    // MARK: multi-value response headers (multiple Set-Cookie)

    func testMultipleSetCookieHeadersOnTheWire() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/cookies")).willReturn(ok().withHeader("Set-Cookie", ["a=1", "b=2"]))
        )
        let cookies = try RawHTTP.headerValues("Set-Cookie", path: "/cookies", host: host, port: port)
        XCTAssertEqual(cookies.count, 2, "expected two distinct Set-Cookie headers, got: \(cookies)")
        XCTAssertTrue(cookies.contains("a=1"))
        XCTAssertTrue(cookies.contains("b=2"))
    }

    // MARK: withBodyFile

    func testBodyFileServed() throws {
        try wireMock.putFile(named: "resp.json", text: #"{"served":"from-file"}"#, contentType: "application/json")
        try wireMock.stubFor(
            get(urlEqualTo("/bf")).willReturn(aResponse().withStatus(200).withBodyFile("resp.json"))
        )
        let (data, response) = try WireMockFixture.hit("bf")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), ["served": "from-file"])
        try wireMock.deleteFile(named: "resp.json")
    }

    // MARK: withJsonBody + content type

    func testJsonBodyContentType() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/jb")).willReturn(okForJson(["id": 7, "ok": true]))
        )
        let (data, response) = try WireMockFixture.hit("jb")
        XCTAssertEqual(response.statusCode, 200)
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.contains("application/json"), "Content-Type was: \(contentType)")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), ["id": 7, "ok": true])
    }

    // MARK: withUniformRandomDelay (lifecycle + lower bound)

    func testUniformRandomDelayLifecycle() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/ud")).willReturn(ok("delayed").withUniformRandomDelay(lower: 300, upper: 500))
        )
        // Uniform lower bound is 300ms; require a real delay (lower bound only).
        let (data, response) = try WireMockFixture.assertTakesAtLeast(0.25) { try WireMockFixture.hit("ud") }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "delayed")
    }

    // MARK: withChunkedDribbleDelay (lifecycle + body intact + timing)

    func testChunkedDribbleDelayLifecycle() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/cd")).willReturn(ok("streamed-body").withChunkedDribbleDelay(numberOfChunks: 5, totalDuration: 400))
        )
        // Read over a raw socket so we can see the body arrive incrementally.
        // The distinguishing behaviour of a *dribble* (vs. a plain fixed delay,
        // which arrives in one shot) is that bytes land across multiple reads
        // spread over the duration — assert that, not just the total elapsed.
        let (raw, chunks) = try RawHTTP.recvTimeline(path: "/cd", host: host, port: port)
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 200"), "status line: \(raw.prefix(24))")
        XCTAssertTrue(raw.contains("streamed-body"), "dribble must not corrupt the body")
        XCTAssertGreaterThanOrEqual(chunks.count, 2,
            "dribble should deliver over multiple reads, not one shot; got \(chunks.count)")
        let span = chunks.last!.offset - chunks.first!.offset
        XCTAssertGreaterThan(span, 0.15,
            "body should be spread across time (span \(span)s of ~400ms) — a fixed delay would span ~0")
    }

    // MARK: withTransformerParameter (consumed by response-template)

    func testTransformerParameter() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/tp")).willReturn(
                ok("greeting={{parameters.greeting}}")
                    .withTransformers("response-template")
                    .withTransformerParameter("greeting", "hello")
            )
        )
        let (data, _) = try WireMockFixture.hit("tp")
        XCTAssertEqual(String(data: data, encoding: .utf8), "greeting=hello")
    }
}
