import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live-server behaviour tests for matchers that were previously golden-only or
/// untested. Each asserts BOTH a matching request (200) and a non-matching one
/// (404), so a broken matcher can't pass. All matchers used here are verified to
/// be accepted by WireMock 3.13.2 (201, not 422); the 4.x-only numeric matchers
/// are covered by golden encoding only.
final class MatcherIntegrationTests: XCTestCase {
    private var wireMock: WireMock!
    private let jsonHeaders = ["Content-Type": "application/json"]
    private let xmlHeaders = ["Content-Type": "application/xml"]

    override func setUp() async throws {
        wireMock = try await WireMockFixture.clientOrSkip()
    }

    override func tearDown() async throws {
        if wireMock != nil { try? await wireMock.resetAll() }
    }

    private func assertMatch(_ result: (Data, HTTPURLResponse), _ message: String = "") {
        XCTAssertEqual(result.1.statusCode, 200, "expected match. \(message)")
    }
    private func assertMiss(_ result: (Data, HTTPURLResponse), _ message: String = "") {
        XCTAssertEqual(result.1.statusCode, 404, "expected no match. \(message)")
    }

    // MARK: binaryEqualTo

    func testBinaryEqualTo() async throws {
        let payload = Data("hello".utf8)
        try await wireMock.stubFor(
            post(urlEqualTo("/bin")).withRequestBody(binaryEqualTo(payload.base64EncodedString())).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("bin", method: "POST", body: payload))
        assertMiss(try await WireMockFixture.hit("bin", method: "POST", body: Data("goodbye".utf8)))
    }

    // MARK: equalToJson flags

    func testEqualToJsonIgnoreArrayOrder() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/aj"))
                .withRequestBody(equalToJson(["items": [1, 2, 3]], ignoreArrayOrder: true))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("aj", method: "POST", headers: jsonHeaders, body: Data(#"{"items":[3,2,1]}"#.utf8)),
                    "reordered array should still match with ignoreArrayOrder")
        assertMiss(try await WireMockFixture.hit("aj", method: "POST", headers: jsonHeaders, body: Data(#"{"items":[1,2]}"#.utf8)),
                   "missing element must not match")
    }

    func testEqualToJsonIgnoreExtraElements() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/ee"))
                .withRequestBody(equalToJson(["a": 1], ignoreExtraElements: true))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("ee", method: "POST", headers: jsonHeaders, body: Data(#"{"a":1,"b":2}"#.utf8)),
                    "extra key allowed with ignoreExtraElements")
        assertMiss(try await WireMockFixture.hit("ee", method: "POST", headers: jsonHeaders, body: Data(#"{"a":2}"#.utf8)),
                   "wrong value must not match")
    }

    // MARK: caseInsensitive / equalToIgnoreCase

    func testEqualToIgnoreCaseHeader() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/ci")).withHeader("X-Env", equalToIgnoreCase("PROD")).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("ci", headers: ["X-Env": "prod"]))
        assertMatch(try await WireMockFixture.hit("ci", headers: ["X-Env": "Prod"]))
        assertMiss(try await WireMockFixture.hit("ci", headers: ["X-Env": "staging"]))
    }

    // MARK: notMatching / notContaining

    func testNotMatchingQueryParam() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/nm")).withQueryParam("q", notMatching("[0-9]+")).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("nm?q=abc"), "non-numeric passes doesNotMatch")
        assertMiss(try await WireMockFixture.hit("nm?q=123"), "numeric fails doesNotMatch")
    }

    func testNotContainingQueryParam() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/nc")).withQueryParam("q", notContaining("bad")).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("nc?q=good"))
        assertMiss(try await WireMockFixture.hit("nc?q=verybad"))
    }

    // MARK: absent (header must be absent)

    func testAbsentHeader() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/ab")).withoutHeader("X-Trace").willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("ab"), "no header -> matches absent")
        assertMiss(try await WireMockFixture.hit("ab", headers: ["X-Trace": "1"]), "present header must fail absent")
    }

    // MARK: matchesJsonSchema

    func testMatchingJsonSchema() async throws {
        let schema: JSONValue = [
            "type": "object",
            "required": ["name"],
            "properties": ["name": ["type": "string"]],
        ]
        try await wireMock.stubFor(
            post(urlEqualTo("/js")).withRequestBody(matchingJsonSchema(schema, version: .v202012)).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("js", method: "POST", headers: jsonHeaders, body: Data(#"{"name":"bob"}"#.utf8)))
        assertMiss(try await WireMockFixture.hit("js", method: "POST", headers: jsonHeaders, body: Data(#"{"name":5}"#.utf8)),
                   "wrong type violates schema")
        assertMiss(try await WireMockFixture.hit("js", method: "POST", headers: jsonHeaders, body: Data(#"{}"#.utf8)),
                   "missing required violates schema")
    }

    // MARK: equalToXml with placeholders

    func testEqualToXmlWithPlaceholders() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/xp"))
                .withRequestBody(StringValuePattern.equalToXml("<msg><id>${xmlunit.ignore}</id></msg>", enablePlaceholders: true))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("xp", method: "POST", headers: xmlHeaders, body: Data("<msg><id>anything</id></msg>".utf8)),
                    "placeholder ignores the id value")
        assertMiss(try await WireMockFixture.hit("xp", method: "POST", headers: xmlHeaders, body: Data("<msg><name>x</name></msg>".utf8)),
                   "different structure must not match")
    }

    // MARK: matchingXPath with namespaces

    func testMatchingXPathWithNamespaces() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/xn"))
                .withRequestBody(matchingXPath("/t:note/t:to[text()='Bob']", namespaces: ["t": "urn:test"]))
                .willReturn(ok())
        )
        let matched = try await WireMockFixture.hit("xn", method: "POST", headers: xmlHeaders,
            body: Data(#"<t:note xmlns:t="urn:test"><t:to>Bob</t:to></t:note>"#.utf8))
        assertMatch(matched)
        let missed = try await WireMockFixture.hit("xn", method: "POST", headers: xmlHeaders,
            body: Data(#"<t:note xmlns:t="urn:test"><t:to>Alice</t:to></t:note>"#.utf8))
        assertMiss(missed)
    }

    // MARK: before / after / equalToDateTime

    func testDateTimeMatchers() async throws {
        // Match requests whose ?d query is a datetime before 2030.
        try await wireMock.stubFor(
            get(urlPathEqualTo("/before")).withQueryParam("d", before("2030-01-01T00:00:00Z")).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("before?d=2020-06-01T00:00:00Z"))
        assertMiss(try await WireMockFixture.hit("before?d=2040-06-01T00:00:00Z"))

        try await wireMock.stubFor(
            get(urlPathEqualTo("/after")).withQueryParam("d", after("2020-01-01T00:00:00Z")).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("after?d=2025-06-01T00:00:00Z"))
        assertMiss(try await WireMockFixture.hit("after?d=2010-06-01T00:00:00Z"))

        try await wireMock.stubFor(
            get(urlPathEqualTo("/eq")).withQueryParam("d", equalToDateTime("2020-01-01T00:00:00Z")).willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("eq?d=2020-01-01T00:00:00Z"))
        assertMiss(try await WireMockFixture.hit("eq?d=2020-01-02T00:00:00Z"))
    }

    // MARK: and / or / not (logical combinators)

    func testAndCombinator() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/and"))
                .withQueryParam("q", and(containing("foo"), notContaining("bar")))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("and?q=foobaz"))
        assertMiss(try await WireMockFixture.hit("and?q=foobar"), "contains bar -> fails AND")
        assertMiss(try await WireMockFixture.hit("and?q=baz"), "missing foo -> fails AND")
    }

    func testOrCombinator() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/or"))
                .withQueryParam("q", or(equalTo("red"), equalTo("blue")))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("or?q=red"))
        assertMatch(try await WireMockFixture.hit("or?q=blue"))
        assertMiss(try await WireMockFixture.hit("or?q=green"))
    }

    func testNotCombinator() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/not"))
                .withQueryParam("q", not(equalTo("secret")))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("not?q=public"))
        assertMiss(try await WireMockFixture.hit("not?q=secret"))
    }

    // MARK: hasExactly — wrong count must NOT match

    func testHasExactlyWrongCount() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/he"))
                .withQueryParam("id", .hasExactly([equalTo("1"), equalTo("2")]))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("he?id=1&id=2"))
        assertMiss(try await WireMockFixture.hit("he?id=1&id=2&id=3"), "3 values != exactly 2")
        assertMiss(try await WireMockFixture.hit("he?id=1"), "1 value != exactly 2")
    }

    // MARK: urlPathTemplate + pathParameters

    func testUrlPathTemplateWithPathParam() async throws {
        try await wireMock.stubFor(
            get(urlPathTemplate("/things/{id}"))
                .withPathParam("id", matching("[0-9]+"))
                .willReturn(ok("thing"))
        )
        assertMatch(try await WireMockFixture.hit("things/42"))
        assertMiss(try await WireMockFixture.hit("things/abc"), "non-numeric path param must not match")
    }

    // MARK: formParameters

    func testFormParameters() async throws {
        try await wireMock.stubFor(
            post(urlPathEqualTo("/form"))
                .withFormParam("name", equalTo("bob"))
                .willReturn(ok())
        )
        let formHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        assertMatch(try await WireMockFixture.hit("form", method: "POST", headers: formHeaders, body: Data("name=bob&age=3".utf8)))
        assertMiss(try await WireMockFixture.hit("form", method: "POST", headers: formHeaders, body: Data("name=alice".utf8)))
    }

    // MARK: host / port / scheme

    func testHostPortSchemeMatching() async throws {
        // Positive: values that match this server's actual request line.
        let port = WireMockFixture.baseURL.port ?? 8080
        let host = WireMockFixture.baseURL.host ?? "localhost"
        try await wireMock.stubFor(
            get(urlPathEqualTo("/hp"))
                .withHost(equalTo(host))
                .withPort(port)
                .withScheme("http")
                .willReturn(ok("hp"))
        )
        assertMatch(try await WireMockFixture.hit("hp"))

        // Negative: a wrong port on the same request must not match.
        try await wireMock.resetAll()
        try await wireMock.stubFor(
            get(urlPathEqualTo("/hp")).withPort(1).willReturn(ok())
        )
        assertMiss(try await WireMockFixture.hit("hp"), "wrong port must not match")
    }

    // MARK: multipart ALL vs ANY
    //
    // matchingType controls how the pattern applies across the request's PARTS:
    // ALL means every part must match the bodyPatterns; ANY means at least one
    // part must. (Within a part, all bodyPatterns are ANDed.)

    func testMultipartMatchingTypeAllVsAny() async throws {
        let boundary = "BND"
        // A body with two parts, each carrying the given content.
        func twoParts(_ p1: String, _ p2: String) -> Data {
            let text = "--\(boundary)\r\nContent-Disposition: form-data; name=\"p1\"\r\n\r\n\(p1)\r\n"
                + "--\(boundary)\r\nContent-Disposition: form-data; name=\"p2\"\r\n\r\n\(p2)\r\n"
                + "--\(boundary)--\r\n"
            return Data(text.utf8)
        }
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]

        // ALL: every part must contain "target".
        try await wireMock.stubFor(
            post(urlEqualTo("/all"))
                .withMultipartRequestBody(MultipartValuePattern(matchingType: .all, bodyPatterns: [containing("target")]))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("all", method: "POST", headers: headers, body: twoParts("target a", "target b")),
                    "ALL matches when every part contains target")
        assertMiss(try await WireMockFixture.hit("all", method: "POST", headers: headers, body: twoParts("target a", "other b")),
                   "ALL fails when one part lacks target")

        // ANY: at least one part must contain "target".
        try await wireMock.resetAll()
        try await wireMock.stubFor(
            post(urlEqualTo("/any"))
                .withMultipartRequestBody(MultipartValuePattern(matchingType: .any, bodyPatterns: [containing("target")]))
                .willReturn(ok())
        )
        assertMatch(try await WireMockFixture.hit("any", method: "POST", headers: headers, body: twoParts("target a", "other b")),
                    "ANY matches when at least one part contains target")
        assertMiss(try await WireMockFixture.hit("any", method: "POST", headers: headers, body: twoParts("other a", "other b")),
                   "ANY fails when no part contains target")
    }
}
