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
final class MatcherIntegrationTests: WireMockIntegrationCase {
    private let jsonHeaders = ["Content-Type": "application/json"]
    private let xmlHeaders = ["Content-Type": "application/xml"]

    // MARK: binaryEqualTo

    func testBinaryEqualTo() throws {
        let payload = Data("hello".utf8)
        try wireMock.stubFor(
            post(urlEqualTo("/bin")).withRequestBody(binaryEqualTo(payload.base64EncodedString())).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("bin", method: "POST", body: payload))
        WireMockFixture.assertMiss(try WireMockFixture.hit("bin", method: "POST", body: Data("goodbye".utf8)))
    }

    // MARK: equalToJson flags

    func testEqualToJsonIgnoreArrayOrder() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/aj"))
                .withRequestBody(equalToJson(["items": [1, 2, 3]], ignoreArrayOrder: true))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("aj", method: "POST", headers: jsonHeaders, body: Data(#"{"items":[3,2,1]}"#.utf8)),
                    "reordered array should still match with ignoreArrayOrder")
        WireMockFixture.assertMiss(try WireMockFixture.hit("aj", method: "POST", headers: jsonHeaders, body: Data(#"{"items":[1,2]}"#.utf8)),
                   "missing element must not match")
    }

    func testEqualToJsonIgnoreExtraElements() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/ee"))
                .withRequestBody(equalToJson(["a": 1], ignoreExtraElements: true))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("ee", method: "POST", headers: jsonHeaders, body: Data(#"{"a":1,"b":2}"#.utf8)),
                    "extra key allowed with ignoreExtraElements")
        WireMockFixture.assertMiss(try WireMockFixture.hit("ee", method: "POST", headers: jsonHeaders, body: Data(#"{"a":2}"#.utf8)),
                   "wrong value must not match")
    }

    func testEqualToJsonBothFlagsTogether() throws {
        // Each flag is tested in isolation above; prove they compose — a body
        // that is BOTH reordered AND has an extra key matches only when both are on.
        try wireMock.stubFor(
            post(urlEqualTo("/both"))
                .withRequestBody(equalToJson(["items": [1, 2, 3]], ignoreArrayOrder: true, ignoreExtraElements: true))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("both", method: "POST", headers: jsonHeaders,
            body: Data(#"{"items":[3,1,2],"extra":true}"#.utf8)), "reordered array + extra key should match")
        WireMockFixture.assertMiss(try WireMockFixture.hit("both", method: "POST", headers: jsonHeaders,
            body: Data(#"{"items":[9,9]}"#.utf8)), "a genuinely different value must still miss")
    }

    // MARK: caseInsensitive / equalToIgnoreCase

    func testEqualToIgnoreCaseHeader() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/ci")).withHeader("X-Env", equalToIgnoreCase("PROD")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("ci", headers: ["X-Env": "prod"]))
        WireMockFixture.assertMatch(try WireMockFixture.hit("ci", headers: ["X-Env": "Prod"]))
        WireMockFixture.assertMiss(try WireMockFixture.hit("ci", headers: ["X-Env": "staging"]))
    }

    // MARK: notMatching / notContaining

    func testNotMatchingQueryParam() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/nm")).withQueryParam("q", notMatching("[0-9]+")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("nm?q=abc"), "non-numeric passes doesNotMatch")
        WireMockFixture.assertMiss(try WireMockFixture.hit("nm?q=123"), "numeric fails doesNotMatch")
    }

    func testNotContainingQueryParam() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/nc")).withQueryParam("q", notContaining("bad")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("nc?q=good"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("nc?q=verybad"))
    }

    // MARK: absent (header must be absent)

    func testAbsentHeader() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/ab")).withoutHeader("X-Trace").willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("ab"), "no header -> matches absent")
        WireMockFixture.assertMiss(try WireMockFixture.hit("ab", headers: ["X-Trace": "1"]), "present header must fail absent")
    }

    // MARK: matchesJsonSchema

    func testMatchingJsonSchema() throws {
        let schema: JSONValue = [
            "type": "object",
            "required": ["name"],
            "properties": ["name": ["type": "string"]]
        ]
        try wireMock.stubFor(
            post(urlEqualTo("/js")).withRequestBody(matchingJsonSchema(schema, version: .v202012)).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("js", method: "POST", headers: jsonHeaders, body: Data(#"{"name":"bob"}"#.utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("js", method: "POST", headers: jsonHeaders, body: Data(#"{"name":5}"#.utf8)),
                   "wrong type violates schema")
        WireMockFixture.assertMiss(try WireMockFixture.hit("js", method: "POST", headers: jsonHeaders, body: Data(#"{}"#.utf8)),
                   "missing required violates schema")
    }

    // MARK: equalToXml with placeholders

    func testEqualToXmlWithPlaceholders() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/xp"))
                .withRequestBody(StringValuePattern.equalToXml("<msg><id>${xmlunit.ignore}</id></msg>", enablePlaceholders: true))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("xp", method: "POST", headers: xmlHeaders, body: Data("<msg><id>anything</id></msg>".utf8)),
                    "placeholder ignores the id value")
        WireMockFixture.assertMiss(try WireMockFixture.hit("xp", method: "POST", headers: xmlHeaders, body: Data("<msg><name>x</name></msg>".utf8)),
                   "different structure must not match")
    }

    // MARK: matchingXPath with namespaces

    func testMatchingXPathWithNamespaces() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/xn"))
                .withRequestBody(matchingXPath("/t:note/t:to[text()='Bob']", namespaces: ["t": "urn:test"]))
                .willReturn(ok())
        )
        let matched = try WireMockFixture.hit("xn", method: "POST", headers: xmlHeaders,
            body: Data(#"<t:note xmlns:t="urn:test"><t:to>Bob</t:to></t:note>"#.utf8))
        WireMockFixture.assertMatch(matched)
        let missed = try WireMockFixture.hit("xn", method: "POST", headers: xmlHeaders,
            body: Data(#"<t:note xmlns:t="urn:test"><t:to>Alice</t:to></t:note>"#.utf8))
        WireMockFixture.assertMiss(missed)
    }

    // MARK: before / after / equalToDateTime

    func testDateTimeMatchers() throws {
        // Match requests whose ?d query is a datetime before 2030.
        try wireMock.stubFor(
            get(urlPathEqualTo("/before")).withQueryParam("d", before("2030-01-01T00:00:00Z")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("before?d=2020-06-01T00:00:00Z"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("before?d=2040-06-01T00:00:00Z"))

        try wireMock.stubFor(
            get(urlPathEqualTo("/after")).withQueryParam("d", after("2020-01-01T00:00:00Z")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("after?d=2025-06-01T00:00:00Z"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("after?d=2010-06-01T00:00:00Z"))

        try wireMock.stubFor(
            get(urlPathEqualTo("/eq")).withQueryParam("d", equalToDateTime("2020-01-01T00:00:00Z")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("eq?d=2020-01-01T00:00:00Z"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("eq?d=2020-01-02T00:00:00Z"))
    }

    // MARK: and / or / not (logical combinators)

    func testAndCombinator() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/and"))
                .withQueryParam("q", and(containing("foo"), notContaining("bar")))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("and?q=foobaz"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("and?q=foobar"), "contains bar -> fails AND")
        WireMockFixture.assertMiss(try WireMockFixture.hit("and?q=baz"), "missing foo -> fails AND")
    }

    func testOrCombinator() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/or"))
                .withQueryParam("q", or(equalTo("red"), equalTo("blue")))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("or?q=red"))
        WireMockFixture.assertMatch(try WireMockFixture.hit("or?q=blue"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("or?q=green"))
    }

    func testNotCombinator() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/not"))
                .withQueryParam("q", not(equalTo("secret")))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("not?q=public"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("not?q=secret"))
    }

    // MARK: hasExactly — wrong count must NOT match

    func testHasExactlyWrongCount() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/he"))
                .withQueryParam("id", .hasExactly([equalTo("1"), equalTo("2")]))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("he?id=1&id=2"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("he?id=1&id=2&id=3"), "3 values != exactly 2")
        WireMockFixture.assertMiss(try WireMockFixture.hit("he?id=1"), "1 value != exactly 2")
    }

    // MARK: urlPathTemplate + pathParameters

    func testUrlPathTemplateWithPathParam() throws {
        try wireMock.stubFor(
            get(urlPathTemplate("/things/{id}"))
                .withPathParam("id", matching("[0-9]+"))
                .willReturn(ok("thing"))
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("things/42"))
        WireMockFixture.assertMiss(try WireMockFixture.hit("things/abc"), "non-numeric path param must not match")
    }

    // MARK: formParameters

    func testFormParameters() throws {
        try wireMock.stubFor(
            post(urlPathEqualTo("/form"))
                .withFormParam("name", equalTo("bob"))
                .willReturn(ok())
        )
        let formHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        WireMockFixture.assertMatch(try WireMockFixture.hit("form", method: "POST", headers: formHeaders, body: Data("name=bob&age=3".utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("form", method: "POST", headers: formHeaders, body: Data("name=alice".utf8)))
    }

    // MARK: host / port / scheme

    func testHostPortSchemeMatching() throws {
        // Positive: values that match this server's actual request line.
        let port = WireMockFixture.baseURL.port ?? 8080
        let host = WireMockFixture.baseURL.host ?? "localhost"
        try wireMock.stubFor(
            get(urlPathEqualTo("/hp"))
                .withHost(equalTo(host))
                .withPort(port)
                .withScheme("http")
                .willReturn(ok("hp"))
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("hp"))

        // Negative: a wrong port on the same request must not match.
        try wireMock.resetAll()
        try wireMock.stubFor(
            get(urlPathEqualTo("/hp")).withPort(1).willReturn(ok())
        )
        WireMockFixture.assertMiss(try WireMockFixture.hit("hp"), "wrong port must not match")
    }

    func testWrongHostAloneDoesNotMatch() throws {
        // Isolate host: everything else about the request matches; only withHost
        // is wrong. The combined positive above can't prove withHost is enforced
        // (a dropped host constraint would still pass), so pin it on its own.
        try wireMock.stubFor(
            get(urlPathEqualTo("/hostonly")).withHost(equalTo("not-this-host.example")).willReturn(ok())
        )
        WireMockFixture.assertMiss(try WireMockFixture.hit("hostonly"),
                                   "a wrong host alone must prevent the match")
    }

    func testWrongSchemeAloneDoesNotMatch() throws {
        // Isolate scheme: the server is reached over http, so a stub that requires
        // https must NOT match — proving withScheme is enforced independently.
        try wireMock.stubFor(
            get(urlPathEqualTo("/schemeonly")).withScheme("https").willReturn(ok())
        )
        WireMockFixture.assertMiss(try WireMockFixture.hit("schemeonly"),
                                   "an https-only stub must not match an http request")
    }

    // MARK: String equivalence classes (empty / unicode / special chars)

    func testEmptyStringQueryParamMatcher() throws {
        // Boundary: equalTo("") must match a present-but-empty value and reject a
        // non-empty one. (An *absent* body isn't the same as an empty string on
        // this server, so pin the boundary on a present query value.)
        try wireMock.stubFor(
            get(urlPathEqualTo("/emptyq")).withQueryParam("q", equalTo("")).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("emptyq?q="),
                                    "an empty value must match equalTo(\"\")")
        WireMockFixture.assertMiss(try WireMockFixture.hit("emptyq?q=x"),
                                   "a non-empty value must not match equalTo(\"\")")
    }

    func testUnicodeBodyMatcher() throws {
        // Non-ASCII (accents, emoji, CJK) must round-trip through the matcher intact.
        let payload = "café ☕ 日本語"
        try wireMock.stubFor(
            post(urlEqualTo("/uni")).withRequestBody(equalTo(payload)).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("uni", method: "POST", body: Data(payload.utf8)),
                                    "the exact unicode body must match")
        WireMockFixture.assertMiss(try WireMockFixture.hit("uni", method: "POST", body: Data("cafe coffee".utf8)),
                                   "a different (ASCII-folded) body must not match")
    }

    func testSpecialCharacterBodyMatcher() throws {
        // Sub-delimiters and whitespace that often get mangled by encoders. Send
        // an explicit text/plain type: with no Content-Type WireMock tries to
        // form-parse an `a=b&...` body and 500s — that's a content-type concern,
        // not what this test is about (verbatim special-char matching).
        let payload = "a=b & c=d? 50% #frag"
        let textHeaders = ["Content-Type": "text/plain"]
        try wireMock.stubFor(
            post(urlEqualTo("/special")).withRequestBody(equalTo(payload)).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("special", method: "POST", headers: textHeaders, body: Data(payload.utf8)),
                                    "special characters must be compared verbatim")
        WireMockFixture.assertMiss(try WireMockFixture.hit("special", method: "POST", headers: textHeaders, body: Data("a=b".utf8)))
    }

    // MARK: multipart fileName (plain-string, verbatim — previously golden-only)

    func testMultipartFileNameMatchesVerbatim() throws {
        // fileName is a plain String compared verbatim (not a StringValuePattern),
        // so a malformed value would be silently ignored by the server. Prove it
        // is actually enforced: the right filename matches, a wrong one misses.
        let boundary = "BND"
        func filePart(named fileName: String) -> Data {
            let text = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"doc\"; filename=\"\(fileName)\"\r\n"
                + "Content-Type: text/plain\r\n\r\ncontent\r\n"
                + "--\(boundary)--\r\n"
            return Data(text.utf8)
        }
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        try wireMock.stubFor(
            post(urlEqualTo("/upload"))
                .withMultipartRequestBody(
                    MultipartValuePattern(fileName: "report.txt", bodyPatterns: [containing("content")])
                )
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("upload", method: "POST", headers: headers, body: filePart(named: "report.txt")),
                                    "the matching filename part must match")
        WireMockFixture.assertMiss(try WireMockFixture.hit("upload", method: "POST", headers: headers, body: filePart(named: "other.txt")),
                                   "a different filename must not match")
    }

    // MARK: multipart ALL vs ANY
    //
    // matchingType controls how the pattern applies across the request's PARTS:
    // ALL means every part must match the bodyPatterns; ANY means at least one
    // part must. (Within a part, all bodyPatterns are ANDed.)

    func testMultipartMatchingTypeAllVsAny() throws {
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
        try wireMock.stubFor(
            post(urlEqualTo("/all"))
                .withMultipartRequestBody(MultipartValuePattern(matchingType: .all, bodyPatterns: [containing("target")]))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("all", method: "POST", headers: headers, body: twoParts("target a", "target b")),
                    "ALL matches when every part contains target")
        WireMockFixture.assertMiss(try WireMockFixture.hit("all", method: "POST", headers: headers, body: twoParts("target a", "other b")),
                   "ALL fails when one part lacks target")

        // ANY: at least one part must contain "target".
        try wireMock.resetAll()
        try wireMock.stubFor(
            post(urlEqualTo("/any"))
                .withMultipartRequestBody(MultipartValuePattern(matchingType: .any, bodyPatterns: [containing("target")]))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("any", method: "POST", headers: headers, body: twoParts("target a", "other b")),
                    "ANY matches when at least one part contains target")
        WireMockFixture.assertMiss(try WireMockFixture.hit("any", method: "POST", headers: headers, body: twoParts("other a", "other b")),
                   "ANY fails when no part contains target")
    }

    // MARK: Repeated matcher on one header accumulates (deliberate divergence from Java last-wins, end-to-end)

    /// Two `withHeader` calls on the same name AND-combine into one matcher; the
    /// server must accept the `{"and":[…]}` shape and require BOTH constraints.
    /// This is the live counterpart to the golden encoding test — it proves the
    /// combined shape is a real contract the 3.13.2 server honours, not just JSON.
    func testRepeatedHeaderMatcherAccumulatesOnServer() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/andhdr"))
                .withHeader("X-Test", containing("foo"))
                .withHeader("X-Test", containing("bar"))
                .willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("andhdr", headers: ["X-Test": "xfoobar"]),
                    "both constraints satisfied → match")
        WireMockFixture.assertMiss(try WireMockFixture.hit("andhdr", headers: ["X-Test": "foo"]),
                   "only one constraint satisfied → no match")
        WireMockFixture.assertMiss(try WireMockFixture.hit("andhdr", headers: ["X-Test": "bar"]),
                   "only the other constraint satisfied → no match")
    }
}
