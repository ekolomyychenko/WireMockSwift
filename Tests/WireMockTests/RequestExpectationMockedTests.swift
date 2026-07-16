import XCTest
@testable import WireMock

/// Server-less tests of the `expect(...)` layer's client-side control flow, driven
/// by `MockAdminTransport` (a URLProtocol stub of the admin API). Unlike the live
/// `RequestExpectationTests`, these run under the hermetic `muter` command, so the
/// boundary-sensitive logic here — the `refine()` `>= 1` floor and `fetchSorted`'s
/// nil-`loggedDate` ordering — is actually mutation-covered, not only CI-covered.
final class RequestExpectationMockedTests: XCTestCase {

    private func message(of error: Error) -> String {
        (error as? RequestExpectationError)?.message ?? String(describing: error)
    }

    // MARK: - refine() floor: a positive check must still require >= 1 match

    /// `toHaveBeenSent(.atMost(5))` is satisfied by 0, so a following field check
    /// that narrows the count to 0 MUST still fail — otherwise the assertion is
    /// vacuous. Kills the `actual >= 1` → `actual >= 0` mutant on
    /// `RequestExpectation.refine` (invisible to muter via the live suite alone).
    func testPositiveCheckAfterAtMostSpecIsNotVacuous() {
        let mock = MockAdminTransport()
            .enqueueCount(3)          // base toHaveBeenSent(.atMost(5)) — satisfied
            .enqueueCount(0)          // refined toHaveHeader — narrows to zero
            .enqueueNoNearMisses()    // shortfall diagnostic lookup
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveBeenSent(.atMost(5))
                .toHaveHeader("X-Trace", equalTo("abc"))
        ) { error in
            let msg = self.message(of: error)
            XCTAssertTrue(msg.contains("at least 1"), "should re-report against the floor, got: \(msg)")
            XCTAssertFalse(msg.contains("at most"), "must not attribute to the satisfied upper-bound spec: \(msg)")
            XCTAssertTrue(msg.contains("X-Trace"), "should name the failing check: \(msg)")
        }
    }

    /// Same guard for `.lessThan`, the other upper-bound-only spec satisfied by 0.
    func testPositiveCheckAfterLessThanSpecIsNotVacuous() {
        let mock = MockAdminTransport()
            .enqueueCount(2)          // base toHaveBeenSent(.lessThan(5)) — satisfied
            .enqueueCount(0)          // refined check narrows to zero
            .enqueueNoNearMisses()
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveBeenSent(.lessThan(5))
                .toHaveQueryParam("source", equalTo("mobile"))
        ) { error in
            let msg = self.message(of: error)
            XCTAssertTrue(msg.contains("at least 1"), msg)
            XCTAssertFalse(msg.contains("fewer than"), msg)
        }
    }

    /// The floor passes when the narrowed count is >= 1 and still satisfies the
    /// declared spec — guards against a mutant that makes `refine` always throw.
    func testPositiveCheckPassesWhenNarrowedCountIsPositive() throws {
        let mock = MockAdminTransport()
            .enqueueCount(3)          // base toHaveBeenSent(.atLeast(2))
            .enqueueCount(2)          // refined check still >= 1 and satisfies atLeast(2)
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveBeenSent(.atLeast(2))
                .toHaveHeader("X-Trace", equalTo("abc"))
        )
    }

    // MARK: - assertExactly on an empty result reports the floor, not the spec

    /// With no matching request there is nothing to check the exact set on, so the
    /// failure must be attributed to the `.atLeast(1)` floor even though the
    /// declared (upper-bound) spec would be satisfied by 0.
    func testExactParamsOnEmptyReportsFloor() {
        let mock = MockAdminTransport()
            .enqueueFind(rawRequests: "[]")   // fetchSorted -> findAll -> no requests
            .enqueueNoNearMisses()
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
                .toHaveExactlyFormParams(["grant_type": "authorization_code"])
        ) { error in
            let msg = self.message(of: error)
            XCTAssertTrue(msg.contains("at least 1"), msg)
        }
    }

    // MARK: - fetchSorted: a nil loggedDate sorts to the END (?? .max)

    /// `first()`/`last()` order by `loggedDate`, treating a missing timestamp as
    /// `.max` (newest). Pins that fallback so the `?? .max` → `?? .min` mutant dies:
    /// with `.min`, the undated request would sort first and flip both terminals.
    func testNilLoggedDateSortsLast() throws {
        let requests = #"""
        [{"url":"/a","method":"GET","loggedDate":100},
         {"url":"/b","method":"GET"}]
        """#
        let mock = MockAdminTransport()
            .enqueueFind(rawRequests: requests)   // for first()
            .enqueueFind(rawRequests: requests)   // for last()
        let wireMock = mock.client()

        let first = try wireMock.expect(getRequestedFor(anyUrl)).first()
        let last = try wireMock.expect(getRequestedFor(anyUrl)).last()
        XCTAssertEqual(first.url, "/a", "dated request should sort before the undated one")
        XCTAssertEqual(last.url, "/b", "undated request should sort last (loggedDate ?? .max)")
    }

    // MARK: - verifyInOrder: an undated step must not silently pass out-of-order

    /// An undated request (`loggedDate` absent → `.max` in `orderingExists`) that
    /// precedes a dated one has NO valid ordering. The greedy diagnostic walk must
    /// advance its cursor with the same `?? .max` semantics, else it re-places every
    /// step and `verifyInOrder` returns without throwing — a silent false pass.
    func testVerifyInOrderThrowsWhenUndatedStepPrecedesDatedStep() {
        let mock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/a","method":"GET"}]"#)                  // step 0: undated
            .enqueueFind(rawRequests: #"[{"url":"/b","method":"GET","loggedDate":100}]"#) // step 1: dated
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.verifyInOrder([getRequestedFor(anyUrl), getRequestedFor(anyUrl)])
        ) { error in
            XCTAssertTrue(error is SequenceVerificationError, "expected an out-of-order failure, got \(error)")
        }
    }

    // MARK: - toNotHaveFormParam: only a plausibly form-encoded body is a leak

    /// A NON-form body (JSON) whose text incidentally contains `&client_secret=`
    /// must NOT be read as a form param — the content-type-agnostic scan only fires
    /// on a body that plausibly is form-encoded, so this negative passes cleanly.
    func testNotHaveFormParamIgnoresNonFormBodyWithAmpersandSubstring() throws {
        let mock = MockAdminTransport()
            .enqueueCount(1)   // refineNegative floor: the base pattern matched (>= 1)
            .enqueueCount(0)   // refineNegative: no request matches the form-param matcher server-side
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"POST","body":"{\"note\":\"a&client_secret=b\"}"}]"#)
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/x"))).toNotHaveFormParam("client_secret")
        )
    }

    /// The hardening still holds: a genuinely form-encoded body that leaked the param
    /// WITHOUT a form Content-Type (so the server-side matcher missed it) is caught by
    /// the client-side scan.
    func testNotHaveFormParamStillCatchesRealFormLeak() {
        let mock = MockAdminTransport()
            .enqueueCount(1)   // refineNegative floor: the base pattern matched (>= 1)
            .enqueueCount(0)   // server-side form matching misses it (no form Content-Type)
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"POST","body":"client_secret=b&grant_type=x"}]"#)
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/x"))).toNotHaveFormParam("client_secret")
        ) { error in
            XCTAssertTrue(self.message(of: error).contains("client_secret"), self.message(of: error))
        }
    }

    /// Regression: a real form-encoded leak whose value is NOT percent-encoded — a
    /// raw `redirect_uri=https://app/cb`, whose `:`/`/` a strict character allowlist
    /// rejects — must still be caught. The earlier `looksFormEncoded` allowlist let a
    /// single reserved character anywhere in the body suppress the whole scan, so
    /// `client_secret` slipped through as a silent false pass. The blacklist gate
    /// (skip only recognisably structured JSON/XML) fires the scan here.
    func testNotHaveFormParamCatchesLeakWithRawUnencodedValue() {
        let mock = MockAdminTransport()
            .enqueueCount(1)   // refineNegative floor: the base pattern matched (>= 1)
            .enqueueCount(0)   // server-side form matching misses it (no form Content-Type)
            .enqueueFind(rawRequests:
                #"[{"url":"/token","method":"POST","body":"grant_type=authorization_code&redirect_uri=https://app/cb&client_secret=SEKRET"}]"#)
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/token"))).toNotHaveFormParam("client_secret")
        ) { error in
            XCTAssertTrue(self.message(of: error).contains("client_secret"), self.message(of: error))
        }
    }

    /// A malformed-but-clearly-structured body (opens with `{` yet doesn't parse as
    /// JSON) must still be skipped by the leak scan — its incidental `&client_secret=`
    /// substring must not fabricate a phantom form param. Locks the `{`/`[`/`<`
    /// prefix arm of the blacklist, not just the valid-JSON arm.
    func testNotHaveFormParamIgnoresMalformedJsonPrefixBody() throws {
        let mock = MockAdminTransport()
            .enqueueCount(1)   // refineNegative floor: the base pattern matched (>= 1)
            .enqueueCount(0)
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"POST","body":"{\"note\":\"a&client_secret=b\""}]"#)
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/x"))).toNotHaveFormParam("client_secret")
        )
    }

    // MARK: - refineNegative floor: a negative must not pass VACUOUSLY on zero matches

    /// A negative check (`toNot…`) must FAIL when the base pattern matched no request
    /// at all — otherwise a typo'd URL or an un-run flow silently greens a security
    /// negative. Mirrors the positive `refine` floor. Regression for Finding A.
    func testNegativeCheckFailsWhenZeroRequestsMatched() {
        let mock = MockAdminTransport()
            .enqueueCount(0)          // refineNegative floor: base pattern matched nothing
            .enqueueNoNearMisses()    // makeError shortfall diagnostic lookup
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/token"))).toNotHaveQueryParam("client_secret")
        ) { error in
            let msg = self.message(of: error)
            XCTAssertTrue(msg.contains("at least 1"), "should fail against the >= 1 floor: \(msg)")
            XCTAssertTrue(msg.contains("client_secret"), "should name the failing check: \(msg)")
        }
    }

    /// The floor must NOT over-fire: with the base pattern matched and no request
    /// carrying the field, the negative passes. Guards against a mutant that makes
    /// `refineNegative` always throw.
    func testNegativeCheckPassesWhenBaseMatchedAndNoOffender() {
        let mock = MockAdminTransport()
            .enqueueCount(2)   // floor: base matched
            .enqueueCount(0)   // no request carries the header
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/x"))).toNotHaveHeader("X-Debug")
        )
    }

    /// A count spec that explicitly ACCEPTS zero (`.never`) opts out of the floor:
    /// chaining a negative after it is trivially true (no request → nothing leaked)
    /// and must NOT trip the floor. Guards against the over-strict `>= 1` reading.
    func testNegativeAfterNeverSpecPassesVacuously() {
        let mock = MockAdminTransport()
            .enqueueCount(0)   // toNeverHaveBeenSent: 0 requests, .never satisfied
            .enqueueCount(0)   // refineNegative floor: .never is satisfied by 0
            .enqueueCount(0)   // no offender
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(getRequestedFor(urlPathEqualTo("/token")))
                .toNeverHaveBeenSent()
                .toNotHaveQueryParam("client_secret")
        )
    }

    /// A malformed-but-clearly-XML body (opens with `<`) must be skipped by the
    /// form-leak scan — its incidental `&client_secret=` substring must not fabricate
    /// a phantom form param. Locks the `<` arm of `looksStructuredNonForm`.
    func testNotHaveFormParamIgnoresXmlPrefixBody() {
        let mock = MockAdminTransport()
            .enqueueCount(1)   // floor
            .enqueueCount(0)   // no server-side form match
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"POST","body":"<root>&client_secret=b"}]"#)
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/x"))).toNotHaveFormParam("client_secret")
        )
    }

    /// A malformed-but-clearly-array body (opens with `[`) is skipped likewise.
    /// Locks the `[` arm of `looksStructuredNonForm`.
    func testNotHaveFormParamIgnoresJsonArrayPrefixBody() {
        let mock = MockAdminTransport()
            .enqueueCount(1)   // floor
            .enqueueCount(0)
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"POST","body":"[1,2&client_secret=b"}]"#)
        let wireMock = mock.client()

        XCTAssertNoThrow(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/x"))).toNotHaveFormParam("client_secret")
        )
    }

    // MARK: - CountSpec fail-path rendering (each variant reaches the failure message)

    /// `.between` fails both directions: out-of-range-high hits the "too many" dump,
    /// below-range hits the near-miss/shortfall branch — both name "between 2 and 5".
    func testCountSpecBetweenTooManyAndShortfall() {
        let over = MockAdminTransport().enqueueCount(7).enqueueFind(rawRequests: "[]")
        XCTAssertThrowsError(
            try over.client().expect(getRequestedFor(anyUrl)).toHaveBeenSent(.between(2...5))
        ) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("between 2 and 5"), m)
            XCTAssertTrue(m.contains("found 7"), m)
        }
        let under = MockAdminTransport().enqueueCount(1).enqueueNoNearMisses()
        XCTAssertThrowsError(
            try under.client().expect(getRequestedFor(anyUrl)).toHaveBeenSent(.between(2...5))
        ) { XCTAssertTrue(self.message(of: $0).contains("between 2 and 5"), self.message(of: $0)) }
    }

    /// `.moreThan(n)` too-few → shortfall/near-miss branch, names "more than 3".
    func testCountSpecMoreThanShortfall() {
        let mock = MockAdminTransport().enqueueCount(2).enqueueNoNearMisses()
        XCTAssertThrowsError(
            try mock.client().expect(getRequestedFor(anyUrl)).toHaveBeenSent(.moreThan(3))
        ) { XCTAssertTrue(self.message(of: $0).contains("more than 3"), self.message(of: $0)) }
    }

    /// `.lessThan(n)` too-many → "too many" branch (never a shortfall), names "fewer than 3".
    func testCountSpecLessThanTooMany() {
        let mock = MockAdminTransport().enqueueCount(5).enqueueFind(rawRequests: "[]")
        XCTAssertThrowsError(
            try mock.client().expect(getRequestedFor(anyUrl)).toHaveBeenSent(.lessThan(3))
        ) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("fewer than 3"), m)
            XCTAssertTrue(m.contains("found 5"), m)
        }
    }

    /// `.times(n)` OVER-count reaches the `makeError` dump branch, which enumerates the
    /// matched requests (`#1 …`) — the "too many" side of `.times`, untested elsewhere
    /// (only the shortfall side is).
    func testCountSpecTimesOverCountDumpsRequests() {
        let mock = MockAdminTransport()
            .enqueueCount(4)
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"GET"},{"url":"/x","method":"GET"},{"url":"/x","method":"GET"},{"url":"/x","method":"GET"}]"#)
        XCTAssertThrowsError(
            try mock.client().expect(getRequestedFor(anyUrl)).toHaveBeenSent(.times(2))
        ) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("exactly 2"), m)
            XCTAssertTrue(m.contains("found 4"), m)
            XCTAssertTrue(m.contains("#1"), m)   // dump enumerates the matched requests
        }
    }

    /// A held EXACT spec (`.times(2)`) re-checks after a field narrows the count: if the
    /// refined count drops below 2 the check fails, reported against the held spec (not
    /// the `.atLeast(1)` floor). Complements the `.atMost`/`.lessThan` floor tests.
    func testPositiveCheckAfterTimesSpecFailsWhenNarrowedBelow() {
        let mock = MockAdminTransport()
            .enqueueCount(2)          // base .times(2) satisfied
            .enqueueCount(1)          // refined check narrows to 1 (< 2)
            .enqueueNoNearMisses()
        let wireMock = mock.client()
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveBeenSent(.times(2))
                .toHaveHeader("X-Trace", equalTo("abc"))
        ) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("exactly 2"), "held spec, not the floor: \(m)")
            XCTAssertTrue(m.contains("X-Trace"), m)
        }
    }

    // MARK: - because(_:) — caller rationale appended to failures

    /// `.because("…")` appends the rationale to the failing check's message, and the
    /// original message (check name, endpoint) stays intact.
    func testBecauseAppendsRationaleToFailure() {
        let mock = MockAdminTransport().enqueueCount(0).enqueueNoNearMisses()
        XCTAssertThrowsError(
            try mock.client().expect(getRequestedFor(urlPathEqualTo("/token")))
                .because("PKCE is mandatory (RFC 7636)")
                .toHaveQueryParam("code_challenge", matching(".+"))
        ) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("— PKCE is mandatory (RFC 7636)"), "rationale appended: \(m)")
            XCTAssertTrue(m.contains("query param code_challenge"), "original message intact: \(m)")
        }
    }

    /// Without `.because`, no rationale line is added (guards the `reason == nil` arm).
    func testWithoutBecauseNoRationaleLine() {
        let mock = MockAdminTransport().enqueueCount(0).enqueueNoNearMisses()
        XCTAssertThrowsError(
            try mock.client().expect(getRequestedFor(urlPathEqualTo("/token")))
                .toHaveQueryParam("code_challenge", matching(".+"))
        ) { XCTAssertFalse(self.message(of: $0).contains("\n  — "), self.message(of: $0)) }
    }

    // MARK: - Message clarity (W2 endpoint, W3 zero-match hint)

    /// W2: a shortfall names WHICH pattern was under-matched, not just "found 0".
    func testShortfallMessageNamesEndpoint() {
        let mock = MockAdminTransport().enqueueCount(0).enqueueNoNearMisses()
        XCTAssertThrowsError(
            try mock.client().expect(postRequestedFor(urlPathEqualTo("/orders")))
                .toHaveHeader("X-Trace", equalTo("abc"))
        ) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("pattern: POST /orders"), "names the endpoint: \(m)")
            XCTAssertTrue(m.contains("X-Trace"), m)
        }
    }

    /// W3: `single()`/`first()` on zero matches add a "what to check" hint.
    func testZeroMatchTerminalsGiveHint() {
        let m1 = MockAdminTransport().enqueueFind(rawRequests: "[]")
        XCTAssertThrowsError(try m1.client().expect(getRequestedFor(anyUrl)).single()) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("but found 0"), m)
            XCTAssertTrue(m.contains("matched no captured request"), "W3 hint: \(m)")
        }
        let m2 = MockAdminTransport().enqueueFind(rawRequests: "[]")
        XCTAssertThrowsError(try m2.client().expect(getRequestedFor(anyUrl)).first()) { error in
            let m = self.message(of: error)
            XCTAssertTrue(m.contains("but found none"), m)
            XCTAssertTrue(m.contains("matched no captured request"), "W3 hint: \(m)")
        }
    }

    // MARK: - toHaveJsonBody(equalToRaw:) surfaces the layer's own error type

    /// Invalid raw JSON must throw `RequestExpectationError`, not the underlying
    /// `WireMockError` — the layer documents a single error type. Throws before any
    /// server call, so no responses are enqueued.
    func testJsonBodyEqualToRawInvalidThrowsRequestExpectationError() {
        let wireMock = MockAdminTransport().client()
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(anyUrl)).toHaveJsonBody(equalToRaw: "{not valid json")
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, "expected RequestExpectationError, got \(type(of: error))")
            // W4: the underlying reason is surfaced (colon + detail), not swallowed.
            XCTAssertTrue(self.message(of: error).contains("invalid JSON:"), self.message(of: error))
        }
    }

    // MARK: - toHaveJsonBody(equalToFile:) input errors throw HERMETICALLY (before any server call)

    /// A missing file URL and a missing bundle resource both throw the layer's own
    /// `RequestExpectationError` **before** touching the server — so they must be
    /// pinned server-less. The live counterpart lives in the integration
    /// `RequestExpectationFailPathTests`, which XCTSkips without a server and is
    /// invisible to `muter`; this deterministic input-validation path (TESTING.md
    /// principle #4) belongs in the hermetic suite so a skip-storm can't hide it.
    func testJsonBodyFileUrlUnreadableThrowsRequestExpectationError() {
        let wireMock = MockAdminTransport().client()   // no responses enqueued: throw precedes any call
        let bogus = URL(fileURLWithPath: "/nonexistent/definitely-not-here-\(#function).json")
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(anyUrl)).toHaveJsonBody(equalToFile: bogus)
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, "expected RequestExpectationError, got \(type(of: error))")
            XCTAssertTrue(self.message(of: error).contains("Cannot read JSON file"), self.message(of: error))
        }
    }

    /// The bundle overload surfaces a missing resource as the layer's own error naming
    /// the fixture, not a bare Foundation nil — also hermetic (throws before the server).
    func testJsonBodyMissingBundleResourceThrowsRequestExpectationError() {
        let wireMock = MockAdminTransport().client()
        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(anyUrl)).toHaveJsonBody(equalToFile: "nope", bundle: .module)
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, "expected RequestExpectationError, got \(type(of: error))")
            let msg = self.message(of: error)
            XCTAssertTrue(msg.contains("not found in bundle"), msg)
            XCTAssertTrue(msg.contains("nope.json"), "should name the missing fixture: \(msg)")
        }
    }
}
