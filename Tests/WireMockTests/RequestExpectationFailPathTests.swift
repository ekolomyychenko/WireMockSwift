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

    /// A positive field check after an upper-bound-only count spec must NOT
    /// vacuously pass when the field is absent (the narrowed count is 0, which
    /// `.atMost`/`.lessThan` would otherwise accept).
    func testPositiveCheckAfterUpperBoundSpecIsNotVacuous() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/token")).willReturn(ok()))
        try WireMockFixture.hit("token", method: "POST")   // no Authorization header
        try WireMockFixture.hit("token", method: "POST")
        for spec in [CountSpec.atMost(5), .lessThan(5)] {
            XCTAssertThrowsError(
                try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
                    .toHaveBeenSent(spec)
                    .toHaveHeader("Authorization")   // absent -> must fail, not pass
            ) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("header Authorization"), message)
                XCTAssertTrue(message.contains("found 0"), message)
                // The failure must be re-reported against the .atLeast(1) floor, not the
                // satisfied upper-bound spec — pins the `effectiveSpec` rewrite.
                XCTAssertTrue(message.contains("at least 1"), message)
                XCTAssertFalse(message.contains(spec.description), message)
            }
        }
        // Sanity: when the header IS present it still passes under .atMost.
        try wireMock.resetAll()
        try wireMock.stubFor(post(urlPathEqualTo("/token")).willReturn(ok()))
        try WireMockFixture.hit("token", method: "POST", headers: ["Authorization": "Bearer x"])
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
            .toHaveBeenSent(.atMost(5))
            .toHaveHeader("Authorization")
    }

    /// The range/comparison count specs (`.between`/`.moreThan`/`.lessThan`) and an
    /// `.atLeast(n>1)` shortfall must FAIL against a LIVE server, not only under the
    /// hermetic mock — TESTING.md principle #1 wants match+miss on the real server for
    /// each spec (the passing side lives in `RequestExpectationTests.testCountSpecs`).
    /// Each case asserts the spec's own `description` string reaches the message, so a
    /// mutant swapping the rendered spec dies.
    func testRangeAndComparisonCountSpecsFailLive() throws {
        // .between too-many: 6 sent, allowed 2...5.
        try wireMock.stubFor(get(urlPathEqualTo("/r-between")).willReturn(ok()))
        for _ in 0..<6 { try WireMockFixture.hit("r-between") }
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/r-between"))).toHaveBeenSent(.between(2...5))
        ) { error in
            let m = String(describing: error)
            XCTAssertTrue(m.contains("between 2 and 5"), m)
            XCTAssertTrue(m.contains("found 6"), m)
        }

        // .moreThan shortfall: 2 sent, needs > 3.
        try wireMock.stubFor(get(urlPathEqualTo("/r-more")).willReturn(ok()))
        for _ in 0..<2 { try WireMockFixture.hit("r-more") }
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/r-more"))).toHaveBeenSent(.moreThan(3))
        ) { XCTAssertTrue(String(describing: $0).contains("more than 3"), String(describing: $0)) }

        // .lessThan too-many: 5 sent, needs < 3.
        try wireMock.stubFor(get(urlPathEqualTo("/r-less")).willReturn(ok()))
        for _ in 0..<5 { try WireMockFixture.hit("r-less") }
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/r-less"))).toHaveBeenSent(.lessThan(3))
        ) { error in
            let m = String(describing: error)
            XCTAssertTrue(m.contains("fewer than 3"), m)
            XCTAssertTrue(m.contains("found 5"), m)
        }

        // .atLeast(n>1) shortfall: 1 sent, needs >= 3.
        try wireMock.stubFor(get(urlPathEqualTo("/r-least")).willReturn(ok()))
        try WireMockFixture.hit("r-least")
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/r-least"))).toHaveBeenSent(.atLeast(3))
        ) { XCTAssertTrue(String(describing: $0).contains("at least 3"), String(describing: $0)) }
    }

    /// The exact-string `toHaveBody(equalTo:)` and the general positional
    /// `toHaveBody(_ matcher:)` overloads are only asserted in the passing direction
    /// elsewhere (`RequestExpectationTests`). Their misses close principle #1's
    /// "a matcher that always matches would pass" gap on these two entry points.
    func testGeneralBodyMatchersFailOnMismatch() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/gb")).willReturn(ok()))
        try WireMockFixture.hit("gb", method: "POST", body: Data("hello world".utf8))
        // exact-string overload, wrong value. Assert the full failing-check LABEL, not
        // a bare "body" substring that the echoed request dump could also supply.
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/gb"))).toHaveBody(equalTo: "goodbye")
        ) { XCTAssertTrue(String(describing: $0).contains("failing check: body"), String(describing: $0)) }
        // general positional overload, wrong value
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/gb"))).toHaveBody(StringValuePattern.equalTo("goodbye"))
        ) { XCTAssertTrue(String(describing: $0).contains("failing check: body"), String(describing: $0)) }
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
        XCTAssertThrowsError(try expectation.last()) { error in
            XCTAssertTrue(String(describing: error).contains("but found none"), String(describing: error))
        }
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

    /// `toNotHaveHeader`/`toNotHaveCookie` must catch a leak in a LATER request even
    /// when an earlier, clean request also matched the base pattern — the multi-request
    /// footgun the `refineNegative` count design exists to kill. Proven for query at
    /// `testNegativeCatchesLeakDespiteCleanDuplicate`; this pins header + cookie.
    func testNegativeHeaderAndCookieCatchLeakDespiteCleanDuplicate() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/d2")).willReturn(ok()))
        try WireMockFixture.hit("d2")                                                    // clean
        try WireMockFixture.hit("d2", headers: ["X-Debug": "1", "Cookie": "session=leak"])  // leaks

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/d2"))).toNotHaveHeader("X-Debug")
        ) { error in
            let m = String(describing: error)
            XCTAssertTrue(m.contains("no header X-Debug"), m)
            XCTAssertTrue(m.contains("1 carried it"), m)
        }
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/d2"))).toNotHaveCookie("session")
        ) { error in
            let m = String(describing: error)
            XCTAssertTrue(m.contains("no cookie session"), m)
            XCTAssertTrue(m.contains("1 carried it"), m)
        }
    }

    /// Presence overloads must throw when the key is genuinely absent — the query and
    /// form counterparts of the header/cookie presence-fail in `RequestExpectationTests`.
    func testPresenceQueryAndFormFailWhenAbsent() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/pf")).willReturn(ok()))
        try WireMockFixture.hit("pf?a=1", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("x=1".utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/pf"))).toHaveQueryParam("missing")
        ) { XCTAssertTrue(String(describing: $0).contains("query param missing"), String(describing: $0)) }
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/pf"))).toHaveFormParam("missing")
        ) { XCTAssertTrue(String(describing: $0).contains("form param missing"), String(describing: $0)) }
    }

    /// `toHaveQueryParam(_:_:)` with a wrong value must throw NAMING the failing check,
    /// so a mutant erasing the "query param <name>" label dies.
    func testQueryParamWrongValueNamesCheck() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/qv")).willReturn(ok()))
        try WireMockFixture.hit("qv?source=web")
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/qv"))).toHaveQueryParam("source", equalTo("mobile"))
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, String(describing: error))
            XCTAssertTrue(String(describing: error).contains("query param source"), String(describing: error))
        }
    }

    /// `toHaveBody(matching:)` regex mismatch must throw naming the "body matches" check.
    func testBodyMatchingRegexFails() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/bm")).willReturn(ok()))
        try WireMockFixture.hit("bm", method: "POST", body: Data("hello world".utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/bm"))).toHaveBody(matching: "^\\d+$")
        ) { XCTAssertTrue(String(describing: $0).contains("body matches"), String(describing: $0)) }
    }

    /// `toNotHaveFormParam` is only ever asserted in the passing direction elsewhere —
    /// this is its failing positive control: a request that DOES carry the form param
    /// must make it throw (the form counterpart of the header/query/cookie negatives).
    func testNegativeFormParamFailsWhenPresent() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/leak")).willReturn(ok()))
        try WireMockFixture.hit("leak", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("grant_type=password&client_secret=oops".utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/leak"))).toNotHaveFormParam("client_secret")
        ) { XCTAssertTrue(String(describing: $0).contains("no form param client_secret"), String(describing: $0)) }
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
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, String(describing: error))
            XCTAssertTrue(String(describing: error).contains("cookie session"), String(describing: error))
        }
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
        ) { XCTAssertTrue(String(describing: $0).contains("failing check: header X-Tag"), String(describing: $0)) }
    }

    // MARK: - Bearer matching fail + anchor trap

    func testBearerMatchingFailAndAnchorTrap() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/auth")).willReturn(ok()))
        try WireMockFixture.hit("auth", headers: ["Authorization": "Bearer eyJvalid"])
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/auth"))).toHaveBearerToken(matching: "plain.+")
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, "expected RequestExpectationError, got \(type(of: error))")
            XCTAssertTrue(String(describing: error).contains("bearer token"), String(describing: error))
        }
        // '^' anchor lands after the injected "Bearer " prefix -> never matches. Assert
        // it is our own assertion failure (not a server-side regex-compile error, which
        // would also "throw something" and hide the documented anchor footgun).
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/auth"))).toHaveBearerToken(matching: "^eyJ.+")
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, "expected RequestExpectationError, got \(type(of: error))")
            XCTAssertTrue(String(describing: error).contains("bearer token"), String(describing: error))
        }
    }

    // MARK: - XML / XPath body matchers fail paths

    /// A body that differs from the expected XML must fail, naming the xml-body check.
    func testXmlBodyMismatchFails() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/xml")).willReturn(ok()))
        try WireMockFixture.hit("xml", method: "POST",
                                headers: ["Content-Type": "application/xml"],
                                body: Data("<order><id>1</id></order>".utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/xml")))
                .toHaveXmlBody(equalTo: "<order><id>2</id></order>")
        ) { XCTAssertTrue(String(describing: $0).contains("xml body"), String(describing: $0)) }
    }

    /// An XPath that does not select a node fails; and a selected value that does not
    /// satisfy the sub-matcher fails — the value-extraction negative branch.
    func testXPathBodyFailPaths() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/xp")).willReturn(ok()))
        try WireMockFixture.hit("xp", method: "POST",
                                headers: ["Content-Type": "application/xml"],
                                body: Data("<order><id>1</id></order>".utf8))
        // No such node.
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/xp")))
                .toHaveBody(matchingXPath: "/order/missing")
        ) { XCTAssertTrue(String(describing: $0).contains("failing check: xpath /order/missing"), String(describing: $0)) }
        // Node exists but its value fails the sub-matcher.
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/xp")))
                .toHaveBody(matchingXPath: "/order/id", equalTo("2"))
        ) { XCTAssertTrue(String(describing: $0).contains("failing check: xpath /order/id"), String(describing: $0)) }
    }

    // MARK: - toHaveExactlyQueryParams branches

    func testExactQueryParamsBranches() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/q")).willReturn(ok()))
        try WireMockFixture.hit("q?page=1")
        // missing key
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/q"))).toHaveExactlyQueryParams(["page": "1", "size": "20"])
        ) { error in
            let m = String(describing: error)
            XCTAssertTrue(m.contains("Expected exactly query params"), m)
            XCTAssertTrue(m.contains("but had"), m)
        }
        // wrong value, matching keys
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/q"))).toHaveExactlyQueryParams(["page": "2"])
        ) { error in
            let m = String(describing: error)
            // W5: expected and actual quoted symmetrically.
            XCTAssertTrue(m.contains("Expected query param 'page' == \"2\""), m)
            XCTAssertTrue(m.contains("but was [\"1\"]"), m)
        }
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

    /// `toHaveExactly*` must check EVERY matching request, not just the first — the
    /// same clean-duplicate footgun `refineNegative` guards against. Two requests
    /// match; only the SECOND leaks an extra param, so the exact-set check must fail.
    func testExactlyParamsCheckEveryRequestNotJustFirst() throws {
        try wireMock.stubFor(get(urlPathEqualTo("/qq")).willReturn(ok()))
        try WireMockFixture.hit("qq?page=1")                 // clean, first
        try WireMockFixture.hit("qq?page=1&debug=true")      // extra param, second
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/qq"))).toHaveExactlyQueryParams(["page": "1"])
        ) { XCTAssertTrue(String(describing: $0).contains("Expected exactly query params"), String(describing: $0)) }

        try wireMock.stubFor(post(urlPathEqualTo("/ff")).willReturn(ok()))
        try WireMockFixture.hit("ff", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("grant_type=client_credentials".utf8))                 // clean, first
        try WireMockFixture.hit("ff", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("grant_type=client_credentials&client_secret=leak".utf8)) // leaks, second
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/ff"))).toHaveExactlyFormParams(["grant_type": "client_credentials"])
        ) { XCTAssertTrue(String(describing: $0).contains("Expected exactly form params"), String(describing: $0)) }
    }

    /// The empty-set branch of `toHaveExactly*` must report against the `.atLeast(1)`
    /// floor, not the declared upper-bound spec (which 0 *satisfies*). Otherwise the
    /// message reads "at most 3 … found 0", misattributing the failure.
    func testExactlyParamsEmptyReportsAtLeastOneNotUpperBound() throws {
        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/exact-none")))
                .toHaveBeenSent(.atMost(3))                 // satisfied by 0, does not throw
                .toHaveExactlyQueryParams(["page": "1"])    // 0 requests -> must report the floor
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("at least 1"), message)
            XCTAssertFalse(message.contains("at most 3"), message)
        }
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
        // Invalid raw JSON surfaces as the layer's own RequestExpectationError (not the
        // underlying WireMockError), consistent with the file/bundle overloads below.
        XCTAssertThrowsError(
            try wireMock.expect(anyRequestedFor(anyUrl)).toHaveJsonBody(equalToRaw: "{bad")
        ) { XCTAssertTrue($0 is RequestExpectationError, String(describing: $0)) }
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
        // toHaveNonEmptyBody must FAIL on a truly-empty body (its own fail-path).
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/e1"))).toHaveNonEmptyBody()
        ) { XCTAssertTrue(String(describing: $0).contains("non-empty body"), String(describing: $0)) }
    }

    func testJsonPathNegativeAndMixedBodyName() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/jp")).willReturn(ok()))
        try WireMockFixture.hit("jp", method: "POST", body: Data(#"{"a":1}"#.utf8))
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/jp"))).toHaveJsonPath("$.missing")
        ) { XCTAssertTrue(String(describing: $0).contains("json path $.missing"), String(describing: $0)) }
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/jp"))).toHaveJsonPath("$.a", equalTo("999"))
        ) { XCTAssertTrue(String(describing: $0).contains("json path $.a"), String(describing: $0)) }
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
