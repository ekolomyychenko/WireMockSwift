import XCTest
@testable import WireMock

/// End-to-end assertions for an OAuth 2.0 / OIDC flow against a live WireMock,
/// exercising the identity-provider helpers: presence checks, form-param
/// correlation on the token endpoint, `verifyInOrder`, and JWT claim extraction.
///
/// Needs a running server; skips (or fails under `WIREMOCK_REQUIRED=1`) otherwise.
final class OAuthFlowTests: WireMockIntegrationCase {

    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Runs the whole authorize -> token -> userinfo flow against a catch-all
    /// stub, with small gaps so journal timestamps strictly increase (the journal
    /// resolves to milliseconds). Returns the JWT used as `client_assertion`.
    @discardableResult
    private func driveFlow() throws -> String {
        try wireMock.stubFor(any(anyUrl).willReturn(ok()))

        let assertion = [b64url(#"{"alg":"RS256","typ":"JWT"}"#),
                         b64url(#"{"iss":"my-client-id","aud":"https://idp/token","sub":"my-client-id"}"#),
                         "sig"].joined(separator: ".")

        // 1) /authorize (PKCE, state, nonce)
        try WireMockFixture.hit("authorize?response_type=code&client_id=my-client-id"
            + "&redirect_uri=https%3A%2F%2Fapp%2Fcb&scope=openid%20profile"
            + "&state=xyz-state&nonce=nnn&code_challenge=CHAL123&code_challenge_method=S256")
        Thread.sleep(forTimeInterval: 0.02)

        // 2) /token (form-encoded, client_assertion JWT, PKCE verifier)
        let tokenBody = "grant_type=authorization_code&code=AUTHCODE"
            + "&redirect_uri=https%3A%2F%2Fapp%2Fcb&code_verifier=VERIFIER123"
            + "&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer"
            + "&client_assertion=\(assertion)"
        try WireMockFixture.hit("token", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data(tokenBody.utf8))
        Thread.sleep(forTimeInterval: 0.02)

        // 3) /userinfo (bearer)
        try WireMockFixture.hit("userinfo", headers: ["Authorization": "Bearer ACCESS-TOKEN"])
        return assertion
    }

    func testAuthorizePresenceAndSecurityChecks() throws {
        try driveFlow()
        try wireMock.expect(getRequestedFor(urlPathEqualTo("/authorize")))
            .toHaveBeenSentOnce()
            .toHaveQueryParam("state")                         // presence-only overload
            .toHaveQueryParam("nonce")
            .toHaveQueryParam("code_challenge")
            .toHaveQueryParam("response_type", .equalTo("code"))
            .toHaveQueryParam("scope", .containing("openid"))
            .toHaveQueryParam("code_challenge_method", .equalTo("S256"))  // no PKCE downgrade
            .toNotHaveQueryParam("client_secret")             // secret must never be in the URL
    }

    func testTokenFormParamPresenceAndCorrelation() throws {
        try driveFlow()
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
            .toHaveBeenSentOnce()
            .toHaveFormParam("code_verifier")                 // presence-only overload
            .toHaveFormParam("grant_type", .equalTo("authorization_code"))

        // Correlate across requests: the redirect_uri at /token must equal the one at /authorize.
        let authorize = try wireMock.expect(getRequestedFor(urlPathEqualTo("/authorize"))).single()
        let token = try wireMock.expect(postRequestedFor(urlPathEqualTo("/token"))).single()
        XCTAssertEqual(authorize.extract().queryParam("redirect_uri"), token.extract().formParam("redirect_uri"))
        XCTAssertEqual(authorize.extract().queryParam("code_challenge"), "CHAL123")
        XCTAssertEqual(token.extract().formParam("code_verifier"), "VERIFIER123")
    }

    func testClientAssertionJWTClaims() throws {
        try driveFlow()
        let jwt = try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
            .single().extract().jwt(formParam: "client_assertion")
        XCTAssertEqual(jwt.header.objectValue?["alg"]?.stringValue, "RS256")
        XCTAssertEqual(jwt.claim("iss")?.stringValue, "my-client-id")
        XCTAssertEqual(jwt.claim("aud")?.stringValue, "https://idp/token")
    }

    /// Locks the server assumption that backs the presence-only overloads:
    /// WireMock compiles its `matches` regex with DOTALL, so `.matching(".*")` (what
    /// `toHaveFormParam(name)` uses) sees a value spanning a newline as present.
    /// Confirmed live during the escaping audit — an audit initially suspected `.*`
    /// would miss multiline values, but `line1.line2` matches across the `\n` here,
    /// proving DOTALL is on. If a future server dropped it, this goes red instead of
    /// silently under-matching.
    func testPresenceOverloadMatchesMultilineValue() throws {
        try wireMock.stubFor(any(anyUrl).willReturn(ok()))
        try WireMockFixture.hit("probe", method: "POST",
                                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: Data("field=line1%0Aline2".utf8))

        // Presence overload (.matching(".*")) must see the multiline value; the dot
        // in a second matcher spans the newline (DOTALL), both AND-combined on `field`.
        try wireMock.expect(postRequestedFor(urlPathEqualTo("/probe")))
            .toHaveBeenSentOnce()
            .toHaveFormParam("field")                          // presence -> .matching(".*")
            .toHaveFormParam("field", .matching("line1.line2"))

        // Not vacuous: the value truly contains a newline, and matching is
        // full-region, so a partial pattern must NOT match.
        let field = try wireMock.expect(postRequestedFor(urlPathEqualTo("/probe")))
            .single().extract().formParam("field")
        XCTAssertEqual(field, "line1\nline2")
        XCTAssertThrowsError(try wireMock.expect(postRequestedFor(urlPathEqualTo("/probe")))
            .toHaveFormParam("field", .matching("line1")),
            "full-region matching must reject a partial pattern"
        ) { error in
            XCTAssertTrue(error is RequestExpectationError, String(describing: error))
            XCTAssertTrue(String(describing: error).contains("form param field"), String(describing: error))
        }
    }

    func testVerifyInOrderHappyAndWrong() throws {
        try driveFlow()
        let authorize = getRequestedFor(urlPathEqualTo("/authorize"))
        let token = postRequestedFor(urlPathEqualTo("/token"))
        let userinfo = getRequestedFor(urlPathEqualTo("/userinfo"))

        // Correct order verifies.
        try wireMock.verifyInOrder([authorize, token, userinfo])

        // Reversed order fails: userinfo was last, so nothing matches "token after userinfo".
        XCTAssertThrowsError(try wireMock.verifyInOrder([userinfo, token, authorize])) { error in
            XCTAssertTrue(error is SequenceVerificationError, "got \(error)")
            XCTAssertTrue(String(describing: error).contains("out of order"), String(describing: error))
        }

        // A never-sent step fails with the "no request at all" reason.
        XCTAssertThrowsError(try wireMock.verifyInOrder([authorize, getRequestedFor(urlPathEqualTo("/logout"))])) { error in
            XCTAssertTrue(String(describing: error).contains("matched no request at all"), String(describing: error))
        }
    }
}
