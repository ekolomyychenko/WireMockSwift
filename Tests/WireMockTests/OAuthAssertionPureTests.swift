import XCTest
@testable import WireMock

/// Pure-unit tests (no server) for the identity-provider assertion helpers:
/// form-param extraction, JWT decoding, and the sequence-error rendering.
final class OAuthAssertionPureTests: XCTestCase {

    /// The JSON is a compile-time literal, so a decode failure is a test bug —
    /// trap loudly rather than thread `throws` through every caller.
    private func captured(_ json: String) -> CapturedRequest {
        guard let logged = try? JSONDecoder().decode(LoggedRequest.self, from: Data(json.utf8)) else {
            fatalError("invalid fixture JSON: \(json)")
        }
        return CapturedRequest(logged: logged)
    }

    /// base64url with padding stripped — how JWT segments are encoded.
    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Form-param parsing

    func testFormParamsEncodingAndEdges() {
        let body = "grant_type=authorization_code&code=abc&redirect_uri=https%3A%2F%2Fapp%2Fcb"
            + "&code_verifier=x+y&raw=a%2Bb&flag&s=1&s=2"
        let request = captured(#"{"body": "\#(body)"}"#)
        XCTAssertEqual(request.formParam("grant_type"), "authorization_code")
        XCTAssertEqual(request.formParam("redirect_uri"), "https://app/cb")   // %-decoded
        XCTAssertEqual(request.formParam("code_verifier"), "x y")             // '+' -> space
        XCTAssertEqual(request.formParam("raw"), "a+b")                       // %2B -> literal '+'
        XCTAssertEqual(request.formParams("flag"), [""])                      // valueless -> ""
        XCTAssertEqual(request.formParams("s"), ["1", "2"])                   // repeated key
        XCTAssertNil(request.formParam("missing"))
    }

    /// Malformed percent-escapes and a `#` must NOT crash the process — the old
    /// `URLComponents.percentEncodedQuery` setter trapped on these. Left verbatim.
    func testFormParamsMalformedEscapesDoNotCrash() {
        XCTAssertEqual(captured(#"{"body": "pct=50%"}"#).formParam("pct"), "50%")        // bare %
        XCTAssertEqual(captured(#"{"body": "code=SAVE50%OFF"}"#).formParam("code"), "SAVE50%OFF")
        XCTAssertEqual(captured(#"{"url": "/cb?state=abc#frag"}"#).queryParam("state"), ["abc#frag"])
        // A non-form (JSON) body just yields no matches, as documented — not a crash.
        XCTAssertNil(captured(##"{"body": "{\"pct\":\"50%\"}"}"##).formParam("pct"))
        // Well-formed escapes still decode correctly.
        XCTAssertEqual(captured(#"{"body": "a=1%2B1&b=x+y"}"#).formParam("a"), "1+1")
        XCTAssertEqual(captured(#"{"body": "a=1%2B1&b=x+y"}"#).formParam("b"), "x y")
    }

    func testFormParamsEmptyOrAbsentBody() {
        XCTAssertEqual(captured(#"{"body": ""}"#).formParams("x"), [])
        XCTAssertEqual(captured("{}").formParams("x"), [])
        XCTAssertNil(captured("{}").formParam("x"))
    }

    func testExtractorFormParam() {
        let extractor = captured(#"{"body": "client_id=app&code_verifier=abc123"}"#).extract()
        XCTAssertEqual(extractor.formParam("client_id"), "app")
        XCTAssertEqual(extractor.formParam("code_verifier"), "abc123")
        XCTAssertNil(extractor.formParam("nope"))
    }

    // MARK: - JWT decoding

    func testJWTDecodeSignedToken() throws {
        let header = #"{"alg":"RS256","typ":"JWT","kid":"k1"}"#
        let payload = #"{"iss":"client-1","aud":"https://idp","sub":"u1","scope":"openid profile","exp":1893456000}"#
        let token = [b64url(header), b64url(payload), "c2lnbmF0dXJl"].joined(separator: ".")

        let jwt = try JWT(decoding: token)
        XCTAssertEqual(jwt.header.objectValue?["alg"]?.stringValue, "RS256")
        XCTAssertEqual(jwt.claim("iss")?.stringValue, "client-1")
        XCTAssertEqual(jwt.claim("aud")?.stringValue, "https://idp")
        XCTAssertEqual(jwt.claim("scope")?.stringValue, "openid profile")
        XCTAssertEqual(jwt.claim("exp"), .int(1893456000))
        XCTAssertEqual(jwt.rawSignature, "c2lnbmF0dXJl")
        XCTAssertNil(jwt.claim("nonexistent"))
    }

    func testJWTDecodeUnsignedTwoSegment() throws {
        let token = [b64url(#"{"alg":"none"}"#), b64url(#"{"sub":"u2"}"#)].joined(separator: ".")
        let jwt = try JWT(decoding: token)
        XCTAssertEqual(jwt.claim("sub")?.stringValue, "u2")
        XCTAssertEqual(jwt.rawSignature, "")   // no signature segment
    }

    func testJWTDecodeFailures() {
        // Wrong segment count.
        XCTAssertThrowsError(try JWT(decoding: "onlyonesegment")) { assertJWTError($0, contains: "2 or 3") }
        XCTAssertThrowsError(try JWT(decoding: "a.b.c.d")) { assertJWTError($0, contains: "2 or 3") }
        // Invalid base64url in the header.
        XCTAssertThrowsError(try JWT(decoding: "@@." + b64url(#"{"a":1}"#))) { assertJWTError($0, contains: "base64url") }
        // Valid base64url but not JSON in the payload.
        XCTAssertThrowsError(try JWT(decoding: b64url(#"{"a":1}"#) + "." + b64url("not json{"))) {
            assertJWTError($0, contains: "not valid JSON")
        }
        // Valid base64url that decodes to non-UTF8 bytes (0xFF 0xFE) — hits the
        // `String(data:encoding:.utf8) == nil` branch of decodeSegment, reported as
        // "not valid JSON" like a bad-JSON payload.
        XCTAssertThrowsError(try JWT(decoding: b64url(#"{"alg":"none"}"#) + ".__4")) {
            assertJWTError($0, contains: "not valid JSON")
        }
        // A segment whose length % 4 == 1 is invalid base64url (1 leftover char can
        // never be padded to a valid group) — exercises the remainder==1 padding path.
        XCTAssertThrowsError(try JWT(decoding: "AAAAA." + b64url(#"{"a":1}"#))) {
            assertJWTError($0, contains: "base64url")
        }
    }

    /// A payload that is valid JSON but NOT an object (a bare array here) decodes
    /// fine, but `claim(_:)` returns nil for every name — the non-object branch of
    /// `payload.objectValue?[name]`.
    func testJWTClaimNilForNonObjectPayload() throws {
        let token = [b64url(#"{"alg":"none"}"#), b64url("[1,2,3]")].joined(separator: ".")
        let jwt = try JWT(decoding: token)
        XCTAssertEqual(jwt.payload, .array([.int(1), .int(2), .int(3)]))
        XCTAssertNil(jwt.claim("anything"))
    }

    /// The `jwt(header:)` and `jwt(queryParam:)` extractors throw a source-specific
    /// message when the header / query param is absent (only the bearer + form-param
    /// missing paths were covered before).
    func testExtractorJWTMissingHeaderAndQuery() {
        let empty = captured("{}").extract()
        XCTAssertThrowsError(try empty.jwt(header: "DPoP")) { assertJWTError($0, contains: "No 'DPoP' header") }
        XCTAssertThrowsError(try empty.jwt(queryParam: "id_token_hint")) {
            assertJWTError($0, contains: "No 'id_token_hint' query parameter")
        }
    }

    private func assertJWTError(_ error: Error, contains needle: String) {
        XCTAssertTrue(error is RequestExpectationError, "expected RequestExpectationError, got \(error)")
        XCTAssertTrue(String(describing: error).contains(needle), String(describing: error))
    }

    // MARK: - JWT via RequestExtractor

    func testExtractorJWTFromFormAndHeaderAndQuery() throws {
        let jwt = [b64url(#"{"alg":"RS256"}"#), b64url(#"{"iss":"acme"}"#), "sig"].joined(separator: ".")
        let request = captured(#"""
        {"url": "/logout?id_token_hint=\#(jwt)", "headers": {"Authorization": "Bearer \#(jwt)", "DPoP": "\#(jwt)"}, "body": "client_assertion=\#(jwt)"}
        """#)
        let extractor = request.extract()
        XCTAssertEqual(try extractor.bearerJWT().claim("iss")?.stringValue, "acme")
        XCTAssertEqual(try extractor.jwt(header: "DPoP").claim("iss")?.stringValue, "acme")
        XCTAssertEqual(try extractor.jwt(formParam: "client_assertion").claim("iss")?.stringValue, "acme")
        XCTAssertEqual(try extractor.jwt(queryParam: "id_token_hint").claim("iss")?.stringValue, "acme")
    }

    func testExtractorJWTMissingSources() {
        let extractor = captured(#"{"headers": {"Authorization": "Basic abc"}}"#).extract()
        XCTAssertThrowsError(try extractor.bearerJWT()) { assertJWTError($0, contains: "not a Bearer") }
        XCTAssertThrowsError(try captured("{}").extract().bearerJWT()) { assertJWTError($0, contains: "No Authorization") }
        XCTAssertThrowsError(try captured("{}").extract().jwt(formParam: "client_assertion")) {
            assertJWTError($0, contains: "form parameter")
        }
    }

    // MARK: - SequenceVerificationError rendering

    /// Empty input is a no-op that returns before touching the server — so it
    /// succeeds even against an unreachable base URL (short-circuit, no request).
    func testVerifyInOrderEmptyIsNoOp() throws {
        let offline = WireMock(baseURL: URL(string: "http://127.0.0.1:1")!)
        XCTAssertNoThrow(try offline.verifyInOrder([]))
    }

    /// The ordering search must accept a valid assignment that greedy-earliest
    /// misses: with tied timestamps and overlapping step patterns, an earlier
    /// step can yield its request to a later step that is its sole claimant.
    func testOrderingExistsHandlesTiesAndOverlap() throws {
        func req(_ url: String, _ time: Int64) throws -> LoggedRequest {
            try WireMockFixture.decode(LoggedRequest.self, #"{"method":"GET","url":"\#(url)","loggedDate":\#(time)}"#)
        }
        let a = try req("/a", 5)
        let b = try req("/b", 5)

        // step0 matches {A,B}, step1 matches only {A}, all at t=5. Valid: B then A.
        XCTAssertTrue(WireMock.orderingExists([[a, b], [a]], step: 0, cursor: .min, used: []))
        // Genuinely out of order: A(10) then B(5) — no non-decreasing assignment.
        XCTAssertFalse(WireMock.orderingExists([[try req("/a", 10)], [b]], step: 0, cursor: .min, used: []))
        // One physical request cannot satisfy two steps (distinctness).
        XCTAssertFalse(WireMock.orderingExists([[a], [a]], step: 0, cursor: .min, used: []))
        // Empty step list is vacuously satisfiable.
        XCTAssertTrue(WireMock.orderingExists([], step: 0, cursor: .min, used: []))
    }

    /// A missing `loggedDate` is treated as `.max` (newest), so an undated request
    /// can only satisfy the LAST step. Pins the `?? .max` fallback: a mutant to
    /// `?? .min` would place the undated request first and flip these verdicts.
    func testOrderingExistsUndatedRequestSortsLast() throws {
        func req(_ url: String, _ time: Int64) throws -> LoggedRequest {
            try WireMockFixture.decode(LoggedRequest.self, #"{"method":"GET","url":"\#(url)","loggedDate":\#(time)}"#)
        }
        let dated = try req("/a", 5)
        let undated = try WireMockFixture.decode(LoggedRequest.self, #"{"method":"GET","url":"/b"}"#)
        // dated(5) then undated(.max) — non-decreasing, valid.
        XCTAssertTrue(WireMock.orderingExists([[dated], [undated]], step: 0, cursor: .min, used: []))
        // undated(.max) then dated(5) — the undated first would need 5 >= .max, impossible.
        XCTAssertFalse(WireMock.orderingExists([[undated], [dated]], step: 0, cursor: .min, used: []))
    }

    func testSequenceErrorNeverSent() {
        let error = SequenceVerificationError(step: 0, stepSummary: "GET /authorize", hadAnyMatch: false, chosen: [])
        let text = error.description
        XCTAssertTrue(text.contains("step #1 (GET /authorize)"), text)
        XCTAssertTrue(text.contains("matched no request at all"), text)
        XCTAssertTrue(text.contains("no earlier step was satisfied"), text)
    }

    func testSequenceErrorOutOfOrderDumpsChosen() throws {
        let earlier = try WireMockFixture.decode(LoggedRequest.self, #"{"method":"GET","url":"/authorize"}"#)
        let error = SequenceVerificationError(step: 1, stepSummary: "POST /token", hadAnyMatch: true, chosen: [earlier])
        let text = error.description
        XCTAssertTrue(text.contains("step #2 (POST /token)"), text)
        XCTAssertTrue(text.contains("only before the previous step"), text)
        XCTAssertTrue(text.contains("Ordered so far"), text)
        XCTAssertTrue(text.contains("GET /authorize"), text)
    }
}
