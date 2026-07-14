import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live-server coverage for feature areas that were previously golden-only:
/// proxying, faults, response-level delays, multipart, webhooks, multi-value
/// matchers, cookies/basic-auth, XML/XPath, and server info endpoints.
final class FeatureIntegrationTests: XCTestCase {
    private var wireMock: WireMock!
    private var base: URL { WireMockFixture.baseURL }

    override func setUp() async throws {
        wireMock = try await WireMockFixture.clientOrSkip()
    }

    override func tearDown() async throws {
        if wireMock != nil {
            try? await wireMock.setGlobalFixedDelay(0)
            try? await wireMock.resetAll()
        }
    }

    // MARK: Proxy (end-to-end through the same server)

    func testProxying() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/upstream")).willReturn(ok("from-upstream")))
        try await wireMock.stubFor(
            any(urlPathMatching("/gateway/.*"))
                .willReturn(aResponse().proxiedFrom(base.absoluteString).withProxyUrlPrefixToRemove("/gateway"))
        )
        let (data, response) = try await WireMockFixture.hit("gateway/upstream")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "from-upstream")
    }

    // MARK: Faults

    func testAllConnectionFaultsBreakTheConnection() async throws {
        // Each fault must NOT produce a normal, successful response. We accept
        // either a thrown transport error or a non-200 / garbage response, since
        // the exact surfacing differs across URLSession backends
        // (Darwin vs. Linux libcurl), especially for MALFORMED/RANDOM data.
        for fault in [Fault.emptyResponse, .malformedResponseChunk, .randomDataThenClose, .connectionResetByPeer] {
            try await wireMock.resetAll()
            try await wireMock.stubFor(get(urlEqualTo("/boom")).willReturn(ok("SHOULD-NOT-SEE").withFault(fault)))
            do {
                let (data, response) = try await WireMockFixture.hit("boom")
                let body = String(data: data, encoding: .utf8) ?? ""
                XCTAssertFalse(
                    response.statusCode == 200 && body == "SHOULD-NOT-SEE",
                    "fault \(fault) returned a clean successful response"
                )
            } catch {
                // Also acceptable: the connection was broken outright.
            }
        }
    }

    func testProxyHeaderInjection() async throws {
        // Upstream only matches when the injected header is present.
        try await wireMock.stubFor(
            get(urlEqualTo("/up")).withHeader("X-Injected", equalTo("yes")).willReturn(ok("injected"))
        )
        try await wireMock.stubFor(
            any(urlPathMatching("/gw/.*")).willReturn(
                aResponse().proxiedFrom(base.absoluteString)
                    .withProxyUrlPrefixToRemove("/gw")
                    .withAdditionalProxyRequestHeader("X-Injected", "yes")
            )
        )
        let (data, response) = try await WireMockFixture.hit("gw/up")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "injected")
    }

    // MARK: Response-level delay

    func testResponseFixedDelay() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/lag")).willReturn(ok().withFixedDelay(400)))
        let start = Date()
        _ = try await WireMockFixture.hit("lag")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3)
    }

    // MARK: Multipart

    func testMultipartMatching() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/upload"))
                .withMultipartRequestBody(
                    MultipartValuePattern(name: "file", matchingType: .any, bodyPatterns: [containing("hello")])
                )
                .willReturn(ok("received"))
        )
        let boundary = "BOUNDARY123"
        let good = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\nhello world\r\n--\(boundary)--\r\n"
        let bad = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\ngoodbye\r\n--\(boundary)--\r\n"
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]

        let matched = try await WireMockFixture.hit("upload", method: "POST", headers: headers, body: Data(good.utf8))
        XCTAssertEqual(matched.1.statusCode, 200)
        let missed = try await WireMockFixture.hit("upload", method: "POST", headers: headers, body: Data(bad.utf8))
        XCTAssertEqual(missed.1.statusCode, 404)
    }

    // MARK: Webhook (fires a callback we can observe)

    func testWebhookFires() async throws {
        try await wireMock.stubFor(post(urlEqualTo("/receiver")).willReturn(ok()))
        try await wireMock.stubFor(
            post(urlEqualTo("/fire"))
                .withWebhook(WebhookDefinition(method: .post, url: base.appendingPathComponent("receiver").absoluteString, body: "ping"))
                .willReturn(ok())
        )
        _ = try await WireMockFixture.hit("fire", method: "POST")

        // The webhook is asynchronous; poll briefly for the callback.
        var received = 0
        for _ in 0..<20 {
            received = try await wireMock.count(postRequestedFor(urlEqualTo("/receiver")))
            if received >= 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(received, 1, "webhook callback should have hit /receiver")
    }

    func testWebhookJsonBodyDeliveredAsBody() async throws {
        try await wireMock.stubFor(post(urlEqualTo("/receiver2")).willReturn(ok()))
        try await wireMock.stubFor(
            post(urlEqualTo("/fire2"))
                .withWebhook(WebhookDefinition(
                    method: .post,
                    url: base.appendingPathComponent("receiver2").absoluteString,
                    headers: ["Content-Type": "application/json"],
                    jsonBody: ["ok": true]
                ))
                .willReturn(ok())
        )
        _ = try await WireMockFixture.hit("fire2", method: "POST")

        // Poll for the async callback, then assert it carried the JSON body —
        // proving jsonBody is serialized into `body` (WireMock ignores a raw
        // `jsonBody` webhook param).
        var body: String?
        for _ in 0..<20 {
            if let first = try await wireMock.findAll(postRequestedFor(urlEqualTo("/receiver2"))).first {
                body = first.body
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(body, #"{"ok":true}"#, "webhook jsonBody must arrive as a JSON body")
    }

    // MARK: Multi-value matcher

    func testHasExactlyQueryParam() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/multi"))
                .withQueryParam("id", .hasExactly([equalTo("1"), equalTo("2")]))
                .willReturn(ok())
        )
        let matched = try await WireMockFixture.hit("multi?id=1&id=2")
        XCTAssertEqual(matched.1.statusCode, 200)
        let missed = try await WireMockFixture.hit("multi?id=1")
        XCTAssertEqual(missed.1.statusCode, 404)
    }

    // MARK: Cookies & basic auth

    func testCookieAndBasicAuth() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/secure"))
                .withCookie("session", equalTo("abc"))
                .withBasicAuth(username: "user", password: "pass")
                .willReturn(ok("ok"))
        )
        let auth = "Basic " + Data("user:pass".utf8).base64EncodedString()
        let good = try await WireMockFixture.hit("secure", headers: ["Cookie": "session=abc", "Authorization": auth])
        XCTAssertEqual(good.1.statusCode, 200)
        let noCookie = try await WireMockFixture.hit("secure", headers: ["Authorization": auth])
        XCTAssertEqual(noCookie.1.statusCode, 404)
    }

    // MARK: XML / XPath

    func testXmlAndXPathMatching() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/xml"))
                .withRequestBody(matchingXPath("/note/to[text()='Bob']"))
                .willReturn(ok("xml-ok"))
        )
        let headers = ["Content-Type": "application/xml"]
        let matched = try await WireMockFixture.hit("xml", method: "POST", headers: headers, body: Data("<note><to>Bob</to></note>".utf8))
        XCTAssertEqual(matched.1.statusCode, 200)
        let missed = try await WireMockFixture.hit("xml", method: "POST", headers: headers, body: Data("<note><to>Alice</to></note>".utf8))
        XCTAssertEqual(missed.1.statusCode, 404)
    }

    // MARK: Server info & typed settings

    func testHealthAndSettings() async throws {
        let health = try await wireMock.getHealth()
        XCTAssertEqual(health.objectValue?["status"], "healthy")

        try await wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 123))
        let settings = try await wireMock.getGlobalSettings()
        XCTAssertEqual(settings.fixedDelay, 123)
        // Lossless decode: the server always returns proxyPassThrough — it must
        // be captured, not silently dropped.
        XCTAssertNotNil(settings.proxyPassThrough)
        try await wireMock.setGlobalFixedDelay(0)
    }

    func testResetSingleScenario() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/sc")).inScenario("flow").whenScenarioStateIs("Started")
                .willSetStateTo("next").willReturn(ok("a"))
        )
        try await wireMock.stubFor(
            get(urlEqualTo("/sc")).inScenario("flow").whenScenarioStateIs("next").willReturn(ok("b"))
        )
        _ = try await WireMockFixture.hit("sc")                 // advance to "next"
        let advanced = try await WireMockFixture.hit("sc")
        XCTAssertEqual(String(data: advanced.0, encoding: .utf8), "b")

        try await wireMock.resetScenario(name: "flow")
        let reset = try await WireMockFixture.hit("sc")
        XCTAssertEqual(String(data: reset.0, encoding: .utf8), "a")
    }

    // MARK: Custom HTTP method via HTTPMethod

    func testCustomHTTPMethod() async throws {
        try await wireMock.stubFor(request("REPORT", urlEqualTo("/r")).willReturn(ok("reported")))
        let (data, response) = try await WireMockFixture.hit("r", method: "REPORT")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "reported")
    }

    // MARK: includes matcher

    func testIncludesMatcher() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/inc"))
                .withQueryParam("tag", .includes([containing("red")]))
                .willReturn(ok())
        )
        let matched = try await WireMockFixture.hit("inc?tag=bright-red&tag=blue")
        XCTAssertEqual(matched.1.statusCode, 200)
        let missed = try await WireMockFixture.hit("inc?tag=blue&tag=green")
        XCTAssertEqual(missed.1.statusCode, 404)
    }

    // MARK: Response templating (response-template transformer)

    func testResponseTemplating() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/hi"))
                .willReturn(ok("Hello {{request.query.name}}").withTransformers("response-template"))
        )
        let (data, _) = try await WireMockFixture.hit("hi?name=Bob")
        XCTAssertEqual(String(data: data, encoding: .utf8), "Hello Bob")
    }

    // MARK: base64 response body

    func testBase64Body() async throws {
        let payload = Data("binary-ish".utf8)
        try await wireMock.stubFor(
            get(urlEqualTo("/bin")).willReturn(aResponse().withStatus(200).withBase64Body(payload.base64EncodedString()))
        )
        let (data, _) = try await WireMockFixture.hit("bin")
        XCTAssertEqual(data, payload)
    }

    // MARK: anything() matcher

    func testAnythingMatcher() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/any")).withHeader("X-Trace", .anything).willReturn(ok()))
        let matched = try await WireMockFixture.hit("any", headers: ["X-Trace": "anything-goes"])
        XCTAssertEqual(matched.1.statusCode, 200)
        // No meaningful negative exists: WireMock's `anything` (AnythingPattern)
        // matches every value AND an absent header, so a request omitting X-Trace
        // still returns 200 — dropping the matcher would be behaviourally
        // indistinguishable here. The exact wire encoding is asserted in
        // GoldenEncodingTests.testAnythingAndRedirectEncode instead.
    }

    // MARK: Journal removal by pattern / metadata

    func testRemoveServeEventsByPattern() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/rm")).willReturn(ok()))
        try await WireMockFixture.hit("rm")
        try await WireMockFixture.hit("rm")
        let removed = try await wireMock.removeServeEvents(matching: getRequestedFor(urlEqualTo("/rm")))
        XCTAssertEqual(removed.count, 2)
        let remaining = try await wireMock.count(getRequestedFor(urlEqualTo("/rm")))
        XCTAssertEqual(remaining, 0)
    }

    func testRemoveServeEventsByMetadata() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/md")).withMetadata(["team": "x"]).willReturn(ok()))
        try await WireMockFixture.hit("md")
        try await wireMock.removeServeEventsByMetadata(.matchingJsonPath("$.team", equalTo("x")))
        let remaining = try await wireMock.count(getRequestedFor(urlEqualTo("/md")))
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Parity additions (clientIp, version, unmatched mappings, filtered journal)

    func testClientIpMatcherIsApplied() async throws {
        // Our request is not from 9.9.9.9, so the clientIp criterion must reject it.
        try await wireMock.stubFor(get(urlEqualTo("/ip")).withClientIp(equalTo("9.9.9.9")).willReturn(ok()))
        let (_, response) = try await WireMockFixture.hit("ip")
        XCTAssertEqual(response.statusCode, 404)
    }

    func testGetVersion() async throws {
        let version = try await wireMock.getVersion()
        XCTAssertNotNil(version)
        XCTAssertTrue(version?.hasPrefix("3.") ?? false, "expected a 3.x version, got \(version ?? "nil")")
    }

    func testUnmatchedStubMappings() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/never")).willReturn(ok()))
        try await wireMock.stubFor(get(urlEqualTo("/used")).willReturn(ok()))
        _ = try await WireMockFixture.hit("used")

        let unmatched = try await wireMock.findUnmatchedStubMappings()
        XCTAssertTrue(unmatched.contains { $0.request.url == "/never" })
        XCTAssertFalse(unmatched.contains { $0.request.url == "/used" })

        try await wireMock.removeUnmatchedStubMappings()
        let all = try await wireMock.listAllStubMappings()
        XCTAssertFalse(all.contains { $0.request.url == "/never" })
        XCTAssertTrue(all.contains { $0.request.url == "/used" })
    }

    func testGetServeEventsLimit() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/s")).willReturn(ok()))
        for _ in 0..<3 { _ = try await WireMockFixture.hit("s") }
        let limited = try await wireMock.getServeEvents(limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    // NOTE: A full record→replay test (start recording → proxy real traffic →
    // stop → assert a generated stub replays) requires a SEPARATE upstream
    // server: recording against this same instance forms a self-proxy loop that
    // hangs. The recording lifecycle/status and snapshot decoding are covered by
    // AdminIntegrationTests; end-to-end record→replay is intentionally left to an
    // environment with a second server rather than shipped as a flaky self-proxy.
}
