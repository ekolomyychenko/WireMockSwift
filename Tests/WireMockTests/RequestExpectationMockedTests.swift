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
            .enqueueCount(0)   // server-side form matching misses it (no form Content-Type)
            .enqueueFind(rawRequests: #"[{"url":"/x","method":"POST","body":"client_secret=b&grant_type=x"}]"#)
        let wireMock = mock.client()

        XCTAssertThrowsError(
            try wireMock.expect(postRequestedFor(urlPathEqualTo("/x"))).toNotHaveFormParam("client_secret")
        ) { error in
            XCTAssertTrue(self.message(of: error).contains("client_secret"), self.message(of: error))
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
            XCTAssertTrue(self.message(of: error).contains("invalid JSON"), self.message(of: error))
        }
    }
}
