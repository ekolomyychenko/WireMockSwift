import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Integration tests for the BDD-style `expect(...)` layer (needs a live server).
final class RequestExpectationTests: WireMockIntegrationCase {

    // MARK: Count specs

    func testCountSpecs() throws {
        try wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok()))
        for _ in 0..<3 { try WireMockFixture.hit("ping") }

        try wireMock.expect(getRequestedFor(urlEqualTo("/ping"))).toHaveBeenSent(.times(3))
        try wireMock.expect(getRequestedFor(urlEqualTo("/ping"))).toHaveBeenSent(.atLeast(2))
        try wireMock.expect(getRequestedFor(urlEqualTo("/ping"))).toHaveBeenSent(.atMost(3))
        try wireMock.expect(getRequestedFor(urlEqualTo("/ping"))).toHaveBeenSent(.between(2...5))
        try wireMock.expect(getRequestedFor(urlEqualTo("/ping"))).toHaveBeenSent(.moreThan(2))
        try wireMock.expect(getRequestedFor(urlEqualTo("/ping"))).toHaveBeenSent(.lessThan(5))
        try wireMock.expect(getRequestedFor(urlEqualTo("/absent"))).toNeverHaveBeenSent()
    }

    func testTooManyFailureDumpsMatchedRequests() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/orders")).willReturn(ok()))
        for sku in ["ABC", "ABC", "DEF"] {
            try WireMockFixture.hit("orders", method: "POST",
                                    headers: ["Content-Type": "application/json"],
                                    body: Data(#"{"sku":"\#(sku)"}"#.utf8))
        }
        XCTAssertThrowsError(try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).toHaveBeenSent(.once)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("found 3"), message)
            XCTAssertTrue(message.contains("#1"), message)
            XCTAssertTrue(message.contains("#3"), message)
            XCTAssertTrue(message.contains("DEF"), message)
        }
    }

    // MARK: Field checks

    func testFieldChecksHappyPath() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/orders")).willReturn(ok()))
        try WireMockFixture.hit(
            "orders?source=mobile", method: "POST",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer eyJabc"],
            body: Data(#"{"items":[{"sku":"ABC"}],"id":"ord_1"}"#.utf8)
        )

        try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
            .toHaveBeenSent(.once)
            .toHaveHeader("Content-Type", containing("json"))
            .toHaveBearerToken("eyJabc")
            .toHaveBearerToken(matching: "eyJ.+")
            .toHaveQueryParam("source", equalTo("mobile"))
            .toHaveJsonPath("$.id")
            .toHaveJsonPath("$.items[0].sku", equalTo("ABC"))
    }

    /// Presence-only overloads (`toHave{Header,Cookie}(_ name:)`) and the general
    /// positional `toHaveBody(_ matcher:)` — a key must exist with any value.
    func testPresenceOnlyOverloadsAndGeneralBody() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/trace")).willReturn(ok()))
        try WireMockFixture.hit(
            "trace", method: "POST",
            headers: ["X-Trace": "abc123", "Cookie": "sid=s-1"],
            body: Data("hello".utf8)
        )

        try wireMock.expect(postRequestedFor(urlPathEqualTo("/trace")))
            .toHaveHeader("X-Trace")                 // present, any value
            .toHaveCookie("sid")                     // present, any value
            .toHaveBody(StringValuePattern.equalTo("hello"))   // general positional overload

        // Presence fails when the key is genuinely absent.
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/trace"))).toHaveHeader("X-Missing")
        ) { XCTAssertTrue(String(describing: $0).contains("header X-Missing"), String(describing: $0)) }
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/trace"))).toHaveCookie("absent")
        ) { XCTAssertTrue(String(describing: $0).contains("cookie absent"), String(describing: $0)) }
    }

    func testBasicAuth() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/secure")).willReturn(ok()))
        let credentials = Data("bob:secret".utf8).base64EncodedString()
        try WireMockFixture.hit("secure", headers: ["Authorization": "Basic \(credentials)"])

        try wireMock.expect(getRequestedFor(urlPathEqualTo("/secure")))
            .toHaveBeenSent(.once)
            .toHaveBasicAuth(username: "bob", password: "secret")

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/secure")))
                .toHaveBasicAuth(username: "bob", password: "wrong")
        ) { error in
            XCTAssertTrue(String(describing: error).contains("basic auth"), String(describing: error))
        }
    }

    func testJsonSchema() throws {
        let schema: JSONValue = [
            "type": "object",
            "required": ["id"],
            "properties": ["id": ["type": "number"]]
        ]
        try wireMock.stubFor(post(urlPathEqualTo("/valid")).willReturn(ok()))
        try wireMock.stubFor(post(urlPathEqualTo("/invalid")).willReturn(ok()))
        try WireMockFixture.hit("valid", method: "POST", body: Data(#"{"id":1}"#.utf8))
        try WireMockFixture.hit("invalid", method: "POST", body: Data(#"{"name":"x"}"#.utf8))

        try wireMock.expect(postRequestedFor(urlPathEqualTo("/valid")))
            .toHaveJsonBody(matchingSchema: schema, version: .v202012)
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/invalid")))
                .toHaveJsonBody(matchingSchema: schema)
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, String(describing: error))
            XCTAssertTrue(String(describing: error).contains("json schema"), String(describing: error))
        }
    }

    func testExtractorAccessors() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/extract")).willReturn(ok()))
        try WireMockFixture.hit(
            "extract?token=xyz", method: "POST",
            headers: ["X-Trace": "abc"],
            body: Data(#"{"id":"e1"}"#.utf8)
        )
        let extractor = try wireMock.expect(postRequestedFor(urlPathEqualTo("/extract")))
            .toHaveBeenSent(.once)
            .extract()
        XCTAssertEqual(extractor.header("x-trace"), "abc")   // case-insensitive name
        XCTAssertEqual(extractor.queryParam("token"), "xyz")
        XCTAssertEqual(extractor.body(), #"{"id":"e1"}"#)
    }

    func testFailingCheckIsNamed() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/orders")).willReturn(ok()))
        try WireMockFixture.hit("orders", method: "POST",
                                headers: ["Content-Type": "application/json"],
                                body: Data(#"{"id":"ord_1"}"#.utf8))

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveBeenSent(.once)
                .toHaveBearerToken("nope")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("bearer token"), message)
        }
    }

    func testNegativeChecks() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/clean")).willReturn(ok()))
        try WireMockFixture.hit("clean")

        try wireMock.expect(getRequestedFor(urlPathEqualTo("/clean")))
            .toHaveBeenSent(.once)
            .toNotHaveHeader("X-Debug")
            .toNotHaveCookie("session")
            .toNotHaveQueryParam("token")
    }

    // MARK: JSON body full vs partial

    func testJsonBodyFullVsPartial() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/full")).willReturn(ok()))
        try WireMockFixture.hit("full", method: "POST",
                                body: Data(#"{"a":1,"b":2,"c":3}"#.utf8))

        // Strict full match fails because of the extra "c".
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/full")))
                .toHaveJsonBody(equalTo: ["a": 1, "b": 2])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("json body"), String(describing: error))
        }
        // Ignoring extra elements passes.
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/full")))
            .toHaveJsonBody(equalTo: ["a": 1, "b": 2], ignoreExtraElements: true)
    }

    func testJsonNumberMatchedAsString() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/num")).willReturn(ok()))
        try WireMockFixture.hit("num", method: "POST", body: Data(#"{"qty":2}"#.utf8))
        // JSON number 2 is compared as the string "2".
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/num")))
            .toHaveJsonPath("$.qty", equalTo("2"))
    }

    // MARK: Text body

    func testTextBodyMatchers() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/text")).willReturn(ok()))
        try WireMockFixture.hit("text", method: "POST", body: Data("hello world".utf8))

        try wireMock.expect(postRequestedFor(urlPathEqualTo("/text")))
            .toHaveBeenSent(.once)
            .toHaveBody(equalTo: "hello world")
            .toHaveBody(containing: "world")
            .toHaveBody(matching: "hel.*rld")
            .toHaveNonEmptyBody()
    }

    func testEmptyVsNonEmptyBody() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/nobody")).willReturn(ok()))
        try wireMock.stubFor(post(urlPathEqualTo("/withbody")).willReturn(ok()))
        try WireMockFixture.hit("nobody")
        try WireMockFixture.hit("withbody", method: "POST", body: Data("x".utf8))

        try wireMock.expect(getRequestedFor(urlPathEqualTo("/nobody"))).toHaveEmptyBody()
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/withbody"))).toHaveNonEmptyBody()
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/withbody"))).toHaveEmptyBody()
        ) { error in
            XCTAssertTrue(String(describing: error).contains("empty body"), String(describing: error))
        }
    }

    func testNegativeBodyNeverSent() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/pay")).willReturn(ok()))
        try WireMockFixture.hit("pay", method: "POST", body: Data(#"{"amount":10}"#.utf8))
        // No request carried "topsecret" in its body — fold the body constraint
        // into the pattern, then assert it never happened (Java's
        // `verify(never(), ...withRequestBody(...))` idiom).
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/pay")).withRequestBody(containing("topsecret")))
            .toNeverHaveBeenSent()
    }

    // MARK: Form params

    func testFormParams() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/token")).willReturn(ok()))
        try WireMockFixture.hit(
            "token", method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("grant_type=password&username=bob".utf8)
        )
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
            .toHaveBeenSent(.once)
            .toHaveFormParam("grant_type", equalTo("password"))
            .toHaveFormParam("username", equalTo("bob"))
            .toNotHaveFormParam("client_secret")
    }

    /// M2 regression: a form-encoded body sent WITHOUT the form content type is not
    /// parsed as `formParameters` server-side, so the server-only negative would
    /// falsely pass while the secret is physically in the body. `toNotHaveFormParam`
    /// also scans the captured body client-side, so it must still catch the leak.
    func testNotHaveFormParamCatchesLeakWithoutFormContentType() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/token")).willReturn(ok()))
        // Deliberately text/plain, not application/x-www-form-urlencoded.
        try WireMockFixture.hit(
            "token", method: "POST",
            headers: ["Content-Type": "text/plain"],
            body: Data("grant_type=authorization_code&client_secret=LEAKED".utf8)
        )
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
                .toNotHaveFormParam("client_secret")
        ) { error in
            let msg = (error as? RequestExpectationError)?.message ?? "\(error)"
            XCTAssertTrue(msg.contains("client_secret"), msg)
            XCTAssertTrue(msg.contains("in the body"), msg)
        }
    }

    // MARK: XML body

    func testXmlBodyAndXPath() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/xml")).willReturn(ok()))
        try WireMockFixture.hit(
            "xml", method: "POST",
            headers: ["Content-Type": "application/xml"],
            body: Data("<order><id>7</id></order>".utf8)
        )
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/xml")))
            .toHaveBeenSent(.once)
            .toHaveXmlBody(equalTo: "<order><id>7</id></order>")
            .toHaveBody(matchingXPath: "/order/id[text()='7']")
            .toHaveBody(matchingXPath: "/order/id/text()", equalTo("7"))
    }

    func testJsonBodyFromFile() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/file")).willReturn(ok()))
        try WireMockFixture.hit("file", method: "POST", body: Data(#"{"id":7}"#.utf8))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("expect-\(UUID().uuidString).json")
        try Data(#"{"id":7}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try wireMock.expect(postRequestedFor(urlPathEqualTo("/file")))
            .toHaveJsonBody(equalToFile: url)
        // The valid `equalToRaw:` path was only ever covered transitively (via the
        // file overload, which calls it); pin its own live round-trip so the server
        // is proven to accept the parsed operand.
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/file")))
            .toHaveJsonBody(equalToRaw: #"{"id":7}"#)
    }

    // MARK: Capture / extract / correlation

    func testSingleThrowsWhenNotExactlyOne() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/multi")).willReturn(ok()))
        for _ in 0..<2 { try WireMockFixture.hit("multi") }
        XCTAssertThrowsError(try wireMock.expect(getRequestedFor(urlPathEqualTo("/multi"))).single()) { error in
            XCTAssertTrue(String(describing: error).contains("found 2"), String(describing: error))
        }
    }

    // Ordering of first()/last()/all() by loggedDate is pinned deterministically —
    // without a wall-clock/server-timestamp-resolution dependency — in
    // RequestExpectationMockedTests (`first()`/`last()` + the nil-loggedDate-sorts-last
    // case). A live variant here would need a real `Thread.sleep` to force strictly
    // increasing millisecond timestamps and could order-flip on a coarse-clock CI, so
    // it is intentionally omitted.

    func testExtractJsonPathAndCorrelate() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/orders")).willReturn(ok()))
        try wireMock.stubFor(post(urlPathEqualTo("/payments")).willReturn(ok()))

        try WireMockFixture.hit("orders", method: "POST", body: Data(#"{"id":"ord_42"}"#.utf8))
        let orderId = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
            .toHaveBeenSent(.once)
            .extract().jsonPath("$.id")
        XCTAssertEqual(orderId.stringValue, "ord_42")

        try WireMockFixture.hit("payments", method: "POST", body: Data(#"{"orderId":"ord_42"}"#.utf8))
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/payments")))
            .toHaveJsonPath("$.orderId", equalTo(orderId.stringValue ?? ""))
    }

    // MARK: Exact query params

    func testExactlyQueryParams() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/search")).willReturn(ok()))
        try WireMockFixture.hit("search?page=1&size=20")

        try wireMock.expect(getRequestedFor(urlPathEqualTo("/search")))
            .toHaveExactlyQueryParams(["page": "1", "size": "20"])

        try wireMock.stubFor(get(urlPathEqualTo("/search2")).willReturn(ok()))
        try WireMockFixture.hit("search2?page=1&debug=true")
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/search2")))
                .toHaveExactlyQueryParams(["page": "1"])
        ) { error in
            // Assert the specific "extra key" phrasing, not just that "debug"
            // appears somewhere (it's also in the request URL echoed in the dump).
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Expected exactly query params"), message)
            XCTAssertTrue(message.contains("but had"), message)
        }
    }

    /// A `toNot*` security negative must catch a leaking request even when a
    /// second, clean request also matched the base pattern — the old
    /// "narrow-by-absent, count >= 1" reading passed here (footgun).
    func testNegativeCatchesLeakDespiteCleanDuplicate() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/authorize")).willReturn(ok()))
        try WireMockFixture.hit("authorize?state=x")                        // clean
        try WireMockFixture.hit("authorize?state=y&client_secret=leak")     // leaks the secret

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/authorize"))).toNotHaveQueryParam("client_secret")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("no query param client_secret"), message)
            XCTAssertTrue(message.contains("1 carried it"), message)
        }
    }

    func testExactlyFormParams() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/token")).willReturn(ok()))
        try WireMockFixture.hit("token", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("grant_type=authorization_code&code=abc".utf8))
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
            .toHaveExactlyFormParams(["grant_type": "authorization_code", "code": "abc"])

        // An extra field in the body (a leaked client_secret) fails the exact set.
        try wireMock.stubFor(post(urlPathEqualTo("/token2")).willReturn(ok()))
        try WireMockFixture.hit("token2", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("grant_type=authorization_code&client_secret=leak".utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/token2")))
                .toHaveExactlyFormParams(["grant_type": "authorization_code"])
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Expected exactly form params"), message)
            XCTAssertTrue(message.contains("but had"), message)
        }
    }
}

/// Pure-unit tests (no server) for the count logic and the JSONPath subset.
final class RequestExpectationUnitTests: XCTestCase {

    func testCountSpecIsSatisfied() {
        XCTAssertTrue(CountSpec.once.isSatisfied(by: 1))
        XCTAssertFalse(CountSpec.once.isSatisfied(by: 2))
        XCTAssertFalse(CountSpec.once.isSatisfied(by: 0))     // once must reject zero (not `<= 1`)
        XCTAssertTrue(CountSpec.never.isSatisfied(by: 0))
        XCTAssertFalse(CountSpec.never.isSatisfied(by: 1))
        XCTAssertTrue(CountSpec.times(3).isSatisfied(by: 3))
        XCTAssertFalse(CountSpec.times(3).isSatisfied(by: 4))  // exactly-N must reject over-count (not `>= n`)
        XCTAssertFalse(CountSpec.times(3).isSatisfied(by: 2))
        XCTAssertTrue(CountSpec.atLeast(2).isSatisfied(by: 2))
        XCTAssertTrue(CountSpec.atLeast(2).isSatisfied(by: 9))
        XCTAssertFalse(CountSpec.atLeast(2).isSatisfied(by: 1))
        XCTAssertTrue(CountSpec.atMost(2).isSatisfied(by: 2))
        XCTAssertFalse(CountSpec.atMost(2).isSatisfied(by: 3))
        XCTAssertTrue(CountSpec.moreThan(2).isSatisfied(by: 3))
        XCTAssertFalse(CountSpec.moreThan(2).isSatisfied(by: 2))
        XCTAssertTrue(CountSpec.lessThan(2).isSatisfied(by: 1))
        XCTAssertFalse(CountSpec.lessThan(2).isSatisfied(by: 2))
        XCTAssertTrue(CountSpec.between(2...5).isSatisfied(by: 2))
        XCTAssertTrue(CountSpec.between(2...5).isSatisfied(by: 5))
        XCTAssertFalse(CountSpec.between(2...5).isSatisfied(by: 6))
        XCTAssertFalse(CountSpec.between(2...5).isSatisfied(by: 1))  // below lower bound (not just `<= upper`)
    }

    func testCountSpecShortfall() {
        XCTAssertTrue(CountSpec.times(3).isShortfall(1))
        XCTAssertFalse(CountSpec.times(3).isShortfall(5))     // excess, not shortfall
        XCTAssertFalse(CountSpec.atMost(2).isShortfall(5))
        XCTAssertFalse(CountSpec.lessThan(2).isShortfall(5))
        XCTAssertTrue(CountSpec.between(2...5).isShortfall(1))
        XCTAssertFalse(CountSpec.between(2...5).isShortfall(9))
        XCTAssertFalse(CountSpec.never.isShortfall(3))
    }

    func testJSONPathLite() throws {
        let json: JSONValue = ["id": "ord_42", "items": [["sku": "ABC"], ["sku": "DEF"]], "nested": ["a": ["b": 7]]]
        XCTAssertEqual(try JSONPathLite.evaluate("$.id", on: json).stringValue, "ord_42")
        XCTAssertEqual(try JSONPathLite.evaluate("$.items[1].sku", on: json).stringValue, "DEF")
        XCTAssertEqual(try JSONPathLite.evaluate("items[0].sku", on: json).stringValue, "ABC")
        XCTAssertEqual(try JSONPathLite.evaluate("$['nested'].a.b", on: json), .int(7))
        XCTAssertEqual(try JSONPathLite.evaluate("$", on: json), json)   // bare root
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.missing", on: json))
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[9]", on: json))
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[", on: json))   // unterminated
    }

    func testJSONPathLiteQuotedNumericKey() throws {
        // A bracket-quoted key that looks like an integer is a key, not an index.
        let json: JSONValue = ["0": "zero", "list": ["a", "b"]]
        XCTAssertEqual(try JSONPathLite.evaluate("$['0']", on: json).stringValue, "zero")
        XCTAssertEqual(try JSONPathLite.evaluate("$.list[0]", on: json).stringValue, "a")   // unquoted = index
    }
}
