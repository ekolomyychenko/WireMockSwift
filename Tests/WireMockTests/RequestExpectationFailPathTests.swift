import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Integration tests focused on the `expect(...)` layer's FAIL paths and error
/// diagnostics — the branches happy-path chains never reach. Needs a live server.
final class RequestExpectationFailPathTests: WireMockIntegrationCase {

    // MARK: - Count fail paths + message content

    func testShortfallNamesFailingCheckWithNearMiss() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/orders")).willReturn(ok()))
        try WireMockFixture.hit("orders", method: "POST", body: Data(#"{"id":1}"#.utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveBeenSent(.once)
                .toHaveHeader("X-Trace", equalTo("z"))   // header absent -> shortfall
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(error is RequestExpectationError, message)
            XCTAssertTrue(message.contains("failing check: header X-Trace"), message)
            XCTAssertTrue(message.contains("Closest match") || message.contains("closest request"), message)
        }
    }

    func testShortfallCountShowsExpectedAndActual() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/orders")).willReturn(ok()))
        try WireMockFixture.hit("orders", method: "POST", body: Data(#"{"id":1}"#.utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).toHaveBeenSent(.times(3))
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("exactly 3"), message)
            XCTAssertTrue(message.contains("found 1"), message)
        }
    }

    func testNeverButSentFailsWithDump() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/tick")).willReturn(ok()))
        try WireMockFixture.hit("tick")
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/tick"))).toNeverHaveBeenSent()
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("exactly 0 (never)"), message)
            XCTAssertTrue(message.contains("found 1"), message)
            XCTAssertTrue(message.contains("#1"), message)
        }
    }

    func testAtMostExceededDumps() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/poll")).willReturn(ok()))
        for _ in 0..<3 { try WireMockFixture.hit("poll") }
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/poll"))).toHaveBeenSent(.atMost(2))
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("at most 2"), message)
            XCTAssertTrue(message.contains("found 3"), message)
            XCTAssertTrue(message.contains("#3"), message)
        }
    }

    func testTooManyDumpTruncatesLongBodyAndShowsContentType() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/big")).willReturn(ok()))
        let longBody = "{\"x\":\"" + String(repeating: "z", count: 120) + "\"}"
        for _ in 0..<2 {
            try WireMockFixture.hit("big", method: "POST",
                                    headers: ["Content-Type": "application/json"],
                                    body: Data(longBody.utf8))
        }
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/big"))).toHaveBeenSent(.once)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("…"), message)                              // body truncated
            XCTAssertTrue(message.contains("Content-Type=application/json"), message)
            XCTAssertFalse(message.contains(String(repeating: "z", count: 120)), "full body should be truncated")
        }
    }

    // MARK: - Terminals on boundaries

    func testSingleThrowsWhenZero() throws {
        XCTAssertThrowsError(try wireMock.expect(getRequestedFor(urlPathEqualTo("/none"))).single()) { error in
            XCTAssertTrue(String(describing: error).contains("found 0"), String(describing: error))
        }
    }

    func testSingleDumpListsCandidates() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/two")).willReturn(ok()))
        for _ in 0..<2 { try WireMockFixture.hit("two") }
        XCTAssertThrowsError(try wireMock.expect(getRequestedFor(urlPathEqualTo("/two"))).single()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("#1") && message.contains("#2"), message)
        }
    }

    func testExtractThrowsWhenZeroAndMany() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/ex")).willReturn(ok()))
        XCTAssertThrowsError(try wireMock.expect(getRequestedFor(urlPathEqualTo("/ex"))).extract()) { error in
            XCTAssertTrue(String(describing: error).contains("found 0"), String(describing: error))
        }
        for _ in 0..<2 { try WireMockFixture.hit("ex") }
        XCTAssertThrowsError(try wireMock.expect(getRequestedFor(urlPathEqualTo("/ex"))).extract()) { error in
            XCTAssertTrue(String(describing: error).contains("found 2"), String(describing: error))
        }
    }

    func testFirstLastAllOnEmpty() throws {
        let expectation = wireMock.expect(getRequestedFor(urlPathEqualTo("/empty")))
        XCTAssertTrue(try expectation.all().isEmpty)
        XCTAssertThrowsError(try expectation.first()) { error in
            XCTAssertTrue(String(describing: error).contains("but found none"), String(describing: error))
        }
        XCTAssertThrowsError(try expectation.last())
    }

    // MARK: - toNot* fail when the field IS present

    func testNegativeChecksFailWhenPresent() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/dirty")).willReturn(ok()))
        try WireMockFixture.hit("dirty?token=1", headers: ["X-Debug": "1", "Cookie": "session=x"])

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/dirty"))).toNotHaveHeader("X-Debug")
        ) { XCTAssertTrue(String(describing: $0).contains("no header X-Debug"), String(describing: $0)) }

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/dirty"))).toNotHaveQueryParam("token")
        ) { XCTAssertTrue(String(describing: $0).contains("no query param token"), String(describing: $0)) }

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/dirty"))).toNotHaveCookie("session")
        ) { XCTAssertTrue(String(describing: $0).contains("no cookie session"), String(describing: $0)) }
    }

    // MARK: - Cookie (positive)

    func testToHaveCookieHappyAndFail() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/c")).willReturn(ok()))
        try WireMockFixture.hit("c", headers: ["Cookie": "session=abc"])
        try wireMock.expect(getRequestedFor(urlPathEqualTo("/c")))
            .toHaveBeenSent(.once)
            .toHaveCookie("session", equalTo("abc"))
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/c"))).toHaveCookie("session", equalTo("nope"))
        )
    }

    // MARK: - Header accumulate-AND (divergence from Java last-wins)

    func testHeaderAccumulatesAsAnd() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/acc")).willReturn(ok()))
        try WireMockFixture.hit("acc", headers: ["X-Tag": "a"])
        // Two matchers on the same header AND together -> "b" is absent, so it fails.
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/acc")))
                .toHaveHeader("X-Tag", equalTo("a"))
                .toHaveHeader("X-Tag", equalTo("b"))
        ) { XCTAssertTrue(String(describing: $0).contains("header X-Tag"), String(describing: $0)) }
    }

    // MARK: - Bearer matching fail + anchor trap

    func testBearerMatchingFailAndAnchorTrap() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/auth")).willReturn(ok()))
        try WireMockFixture.hit("auth", headers: ["Authorization": "Bearer eyJvalid"])
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/auth"))).toHaveBearerToken(matching: "plain.+")
        )
        // '^' anchor lands after the injected "Bearer " prefix -> never matches.
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/auth"))).toHaveBearerToken(matching: "^eyJ.+")
        )
    }

    // MARK: - toHaveExactlyQueryParams branches

    func testExactQueryParamsBranches() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/q")).willReturn(ok()))
        try WireMockFixture.hit("q?page=1")
        // missing key
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/q"))).toHaveExactlyQueryParams(["page": "1", "size": "20"])
        ) { XCTAssertTrue(String(describing: $0).contains("size"), String(describing: $0)) }
        // wrong value, matching keys
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/q"))).toHaveExactlyQueryParams(["page": "2"])
        ) { XCTAssertTrue(String(describing: $0).contains("Expected query param 'page'"), String(describing: $0)) }
        // no matching request at all
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/q-none"))).toHaveExactlyQueryParams(["page": "1"])
        ) { XCTAssertTrue(String(describing: $0).contains("exact query params"), String(describing: $0)) }
    }

    func testExactQueryParamsRepeatedAndValueless() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/q2")).willReturn(ok()))
        try WireMockFixture.hit("q2?a=1&a=2")
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/q2"))).toHaveExactlyQueryParams(["a": "1"])
        ) { XCTAssertTrue(String(describing: $0).contains("Expected query param 'a'"), String(describing: $0)) }

        try wireMock.stubFor(get(urlPathEqualTo("/q3")).willReturn(ok()))
        try WireMockFixture.hit("q3?flag&x=1")
        try wireMock.expect(getRequestedFor(urlPathEqualTo("/q3"))).toHaveExactlyQueryParams(["flag": "", "x": "1"])
    }

    // MARK: - Body branches

    func testJsonBodyIgnoreArrayOrder() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/arr")).willReturn(ok()))
        try WireMockFixture.hit("arr", method: "POST", body: Data(#"{"tags":["b","a"]}"#.utf8))
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/arr")))
            .toHaveJsonBody(equalTo: ["tags": ["a", "b"]], ignoreArrayOrder: true)
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/arr"))).toHaveJsonBody(equalTo: ["tags": ["a", "b"]])
        )
    }

    func testJsonBodyRawInvalidThrowsBeforeServer() {
        XCTAssertThrowsError(
            try wireMock.expect(anyRequestedFor(anyUrl)).toHaveJsonBody(equalToRaw: "{bad")
        ) { XCTAssertTrue($0 is WireMockError, String(describing: $0)) }
    }

    func testJsonBodyFileMissingErrors() throws {
        // URL variant now wraps the Foundation read error as RequestExpectationError.
        let bogus = URL(fileURLWithPath: "/nonexistent/definitely-not-here.json")
        XCTAssertThrowsError(
            try wireMock.expect(anyRequestedFor(anyUrl)).toHaveJsonBody(equalToFile: bogus)
        ) { XCTAssertTrue($0 is RequestExpectationError, String(describing: $0)) }
        // Bundle variant: missing resource.
        XCTAssertThrowsError(
            try wireMock.expect(anyRequestedFor(anyUrl)).toHaveJsonBody(equalToFile: "nope", bundle: .module)
        ) { XCTAssertTrue(String(describing: $0).contains("not found in bundle"), String(describing: $0)) }
    }

    func testJsonBodyFromBundleFixture() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/fx")).willReturn(ok()))
        try WireMockFixture.hit("fx", method: "POST", body: Data(#"{"id":7}"#.utf8))
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/fx")))
            .toHaveBeenSent(.once)
            .toHaveJsonBody(equalToFile: "expect-order", subdirectory: "Fixtures", bundle: .module)
    }

    func testEmptyVsWhitespaceBody() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/e1")).willReturn(ok()))
        try wireMock.stubFor(post(urlPathEqualTo("/e2")).willReturn(ok()))
        try WireMockFixture.hit("e1", method: "POST", body: Data())     // truly empty
        try WireMockFixture.hit("e2", method: "POST", body: Data(" ".utf8))  // whitespace only

        try wireMock.expect(postRequestedFor(urlPathEqualTo("/e1"))).toHaveEmptyBody()
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/e2"))).toHaveNonEmptyBody()   // " " counts as non-empty
        XCTAssertThrowsError(try wireMock.expect(postRequestedFor(urlPathEqualTo("/e2"))).toHaveEmptyBody())
    }

    func testJsonPathNegativeAndMixedBodyName() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/jp")).willReturn(ok()))
        try WireMockFixture.hit("jp", method: "POST", body: Data(#"{"a":1}"#.utf8))
        XCTAssertThrowsError(try wireMock.expect(postRequestedFor(urlPathEqualTo("/jp"))).toHaveJsonPath("$.missing"))
        XCTAssertThrowsError(try wireMock.expect(postRequestedFor(urlPathEqualTo("/jp"))).toHaveJsonPath("$.a", equalTo("999")))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/jp")))
                .toHaveJsonPath("$.a")
                .toHaveBody(containing: "zzz")
        ) { XCTAssertTrue(String(describing: $0).contains("body contains zzz"), String(describing: $0)) }
    }

    // MARK: - Error type contract

    func testFailuresAreRequestExpectationError() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/t")).willReturn(ok()))
        try WireMockFixture.hit("t")
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/t"))).toHaveBeenSent(.times(5))
        ) { XCTAssertTrue($0 is RequestExpectationError, "expected RequestExpectationError, got \(type(of: $0))") }
    }
}
