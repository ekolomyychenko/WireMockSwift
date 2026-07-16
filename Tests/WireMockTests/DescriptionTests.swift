import XCTest
@testable import WireMock

/// Verifies the `description`/`toString` representations used for Allure logging:
/// leaf types render as their bare value, and container types render as their
/// WireMock JSON (mirroring Java `toString()`). Correctness for containers is
/// proven by a round-trip: the description must be valid JSON that decodes back
/// into an equal object.
final class DescriptionTests: XCTestCase {

    /// The description is complete, valid JSON that reconstructs the same value.
    private func assertRoundTrips<T: Codable & Hashable & CustomStringConvertible>(_ value: T,
                                                                                   file: StaticString = #filePath,
                                                                                   line: UInt = #line) throws {
        let again = try WireMockFixture.decode(T.self, value.description)
        XCTAssertEqual(value, again, "description is not faithful JSON for \(T.self)", file: file, line: line)
    }

    // MARK: - Leaf types render as bare values

    func testHTTPMethodDescription() {
        XCTAssertEqual(HTTPMethod.get.description, "GET")
        XCTAssertEqual(HTTPMethod("REPORT").description, "REPORT")
        // The RawRepresentable init (distinct from the string-literal one).
        XCTAssertEqual(HTTPMethod(rawValue: "PATCH").rawValue, "PATCH")
        XCTAssertEqual("\(HTTPMethod.getOrHead)", "GET_OR_HEAD")
    }

    func testFaultDescriptionUsesWireValue() {
        XCTAssertEqual(Fault.emptyResponse.description, "EMPTY_RESPONSE")
        XCTAssertEqual(Fault.connectionResetByPeer.description, "CONNECTION_RESET_BY_PEER")
        XCTAssertEqual(Fault.other("CUSTOM").description, "CUSTOM")
    }

    func testHeaderValueDescription() {
        XCTAssertEqual(HeaderValue.single("application/json").description, "application/json")
        XCTAssertEqual(HeaderValue.multiple(["a", "b"]).description, "[a, b]")
    }

    func testJSONValueDescriptionIsCompactJSON() {
        XCTAssertEqual(JSONValue.null.description, "null")
        XCTAssertEqual(JSONValue.bool(true).description, "true")
        XCTAssertEqual(JSONValue.int(42).description, "42")
        XCTAssertEqual(JSONValue.string("x").description, "\"x\"")
        XCTAssertEqual((["id": 1] as JSONValue).description, #"{"id":1}"#)
        XCTAssertEqual(([1, 2, 3] as JSONValue).description, "[1,2,3]")
        // Slashes are not escaped (readable URLs in logs).
        XCTAssertEqual(JSONValue.string("/a/b").description, "\"/a/b\"")
    }

    /// Literal escaping of the JSON metacharacters. The round-trip property tests
    /// only prove `decode(encode(x)) == x`, which a *symmetric* escape bug would
    /// still satisfy — so pin the actual on-the-wire bytes here.
    func testJSONValueDescriptionEscapesMetacharacters() {
        XCTAssertEqual(JSONValue.string("a\"b").description, "\"a\\\"b\"")   // quote -> \\"
        XCTAssertEqual(JSONValue.string("a\\b").description, "\"a\\\\b\"") // backslash -> \\\\
        XCTAssertEqual(JSONValue.string("a\nb").description, "\"a\\nb\"")     // newline -> \\n
        XCTAssertEqual(JSONValue.string("a\tb").description, "\"a\\tb\"")     // tab -> \\t
        XCTAssertEqual(JSONValue.string("a\u{01}b").description, "\"a\\u0001b\"") // control U+0001 -> \\u0001
        XCTAssertEqual(JSONValue.string("a b").description, "\"a b\"")           // space stays literal
    }

    func testCountMatchingStrategyDescription() {
        // All five cases pinned so a wrong rendering can't slip through.
        XCTAssertEqual(CountMatchingStrategy.exactly(3).description, "exactly 3")
        XCTAssertEqual("\(CountMatchingStrategy.lessThan(4))", "less than 4")
        XCTAssertEqual(CountMatchingStrategy.lessThanOrExactly(2).description, "less than or exactly 2")
        XCTAssertEqual(CountMatchingStrategy.moreThan(5).description, "more than 5")
        XCTAssertEqual("\(CountMatchingStrategy.moreThanOrExactly(1))", "more than or exactly 1")
    }

    func testUrlPatternDescription() {
        // All six kinds pinned (each maps to a distinct wire key).
        XCTAssertEqual(urlEqualTo("/x?q=1").description, "url=/x?q=1")
        XCTAssertEqual(urlMatching("/a.*").description, "urlPattern=/a.*")
        XCTAssertEqual(urlPathEqualTo("/things").description, "urlPath=/things")
        XCTAssertEqual(urlPathMatching("/a.*").description, "urlPathPattern=/a.*")
        XCTAssertEqual(urlPathTemplate("/things/{id}").description, "urlPathTemplate=/things/{id}")
        XCTAssertEqual(anyUrl.description, "anyUrl")
    }

    func testAuthorizationDescriptionMasksSecret() {
        // Pin the exact masked forms (a gutted description would still pass a
        // mere "does not contain the secret" check), and keep the explicit
        // leak-guards as belt-and-suspenders.
        let basic = AdminAuthorization.basic(username: "admin", password: "s3cr3t")
        XCTAssertEqual(basic.description, "basic(username: admin, password: ***)")
        XCTAssertFalse(basic.description.contains("s3cr3t"), "password must not leak")

        let bearer = AdminAuthorization.bearer(token: "tok123")
        XCTAssertEqual(bearer.description, "bearer(token: ***)")
        XCTAssertFalse(bearer.description.contains("tok123"), "token must not leak")

        let header = AdminAuthorization.header(value: "raw-secret")
        XCTAssertEqual(header.description, "header(value: ***)")
        XCTAssertFalse(header.description.contains("raw-secret"), "header value must not leak")
    }

    func testFacadeDescriptionShowsBaseURLNotSecrets() {
        let wm = WireMock(baseURL: URL(string: "http://host:8080")!,
                          authorization: .basic(username: "user", password: "topsecret"))
        XCTAssertTrue(wm.description.contains("http://host:8080"))
        XCTAssertTrue(wm.description.contains("authorized: true"))
        XCTAssertFalse(wm.description.contains("topsecret"), "facade must not leak credentials: \(wm.description)")
    }

    // MARK: - Container types render as faithful JSON (round-trip)

    func testStringValuePatternDescriptionRoundTrips() throws {
        try assertRoundTrips(equalTo("text/plain", caseInsensitive: true))
        try assertRoundTrips(matchingJsonPath("$.name"))
    }

    func testStubMappingDescriptionRoundTrips() throws {
        let stub = post(urlPathEqualTo("/things"))
            .withHeader("Content-Type", equalTo("application/json"))
            .withRequestBody(matchingJsonPath("$.id"))
            .atPriority(2)
            .willReturn(okForJson(["id": 1]))
            .build()
        try assertRoundTrips(stub)
        // And it is actually JSON (starts with a brace), not a reflection dump.
        XCTAssertTrue(stub.description.hasPrefix("{"), stub.description)
    }

    func testRequestPatternAndResponseDefinitionRoundTrip() throws {
        try assertRoundTrips(getRequestedFor(urlEqualTo("/x")).withHeader("H", equalTo("v")).pattern)
        try assertRoundTrips(ok("hi").withHeader("X-A", "y").withFixedDelay(50).definition)
    }

    func testLoggedRequestDescriptionRoundTrips() throws {
        let logged = try WireMockFixture.decode(LoggedRequest.self, #"""
        {"url":"/form","method":"POST","headers":{"Content-Type":"application/json"},
         "body":"{}","queryParams":{},"protocol":"HTTP/1.1"}
        """#)
        try assertRoundTrips(logged)
    }

    func testServeEventAndNearMissDescriptionRoundTrip() throws {
        let event = try WireMockFixture.decode(ServeEvent.self, #"""
        {"request":{"url":"/x","method":"GET"},"wasMatched":true}
        """#)
        try assertRoundTrips(event)

        let nearMiss = try WireMockFixture.decode(NearMiss.self, #"""
        {"request":{"url":"/x","method":"GET"},
         "matchResult":{"distance":0.25,"diffDescriptions":[{"expected":"/y","actual":"/x"}]}}
        """#)
        try assertRoundTrips(nearMiss)
    }

    func testBuilderDescriptionIsStubJSON() throws {
        let builder = get(urlEqualTo("/x")).willReturn(ok())
        XCTAssertTrue(builder.description.hasPrefix("{"), builder.description)
        // The builder's description equals its built mapping's JSON.
        XCTAssertEqual(builder.description, builder.build().description)
    }

    // MARK: - Raw-value enum descriptions (bare wire value)

    func testRawValueEnumDescriptions() {
        XCTAssertEqual(MultipartValuePattern.MatchingType.all.description, "ALL")
        XCTAssertEqual(MultipartValuePattern.MatchingType.any.description, "ANY")
        XCTAssertEqual(StringValuePattern.JSONSchemaVersion.v202012.description, "V202012")
        XCTAssertEqual(StringValuePattern.JSONSchemaVersion.v4.description, "V4")
        XCTAssertEqual(StringValuePattern.NamespaceAwareness.strict.description, "STRICT")
        XCTAssertEqual(StringValuePattern.NamespaceAwareness.off.description, "NONE")
        XCTAssertEqual(StringValuePattern.NamespaceAwareness.legacy.description, "LEGACY")
        XCTAssertEqual(WireMock.DuplicatePolicy.overwrite.description, "OVERWRITE")
        XCTAssertEqual(WireMock.DuplicatePolicy.ignore.description, "IGNORE")
    }

    // MARK: - Error / client descriptions (exact, secrets masked)

    func testWireMockErrorDescriptions() {
        XCTAssertEqual(WireMockError.unexpectedStatus(code: 422, body: "nope").description,
                       "WireMock returned HTTP 422: nope")
        XCTAssertEqual(WireMockError.decodingFailed(underlying: "boom").description,
                       "Failed to decode WireMock response: boom")
        XCTAssertEqual(WireMockError.invalidBaseURL("weird://").description,
                       "Invalid WireMock base URL: weird://")
        XCTAssertEqual(WireMockError.transport(underlying: "refused").description,
                       "WireMock transport error: refused")
        XCTAssertEqual(WireMockError.requestJournalDisabled.description,
                       "The WireMock request journal is disabled; request counts/history are unavailable")
    }

    func testVerificationErrorDescription() {
        XCTAssertEqual(VerificationError(expected: "exactly 2", actual: 3).description,
                       "Expected exactly 2 matching request(s) but found 3")
    }

    func testAdminClientDescriptionShowsBaseURLNotSecrets() {
        let admin = AdminClient(baseURL: URL(string: "http://host:8080")!,
                                authorization: .bearer(token: "s3cr3t"))
        XCTAssertEqual(admin.description, "AdminClient(baseURL: http://host:8080, authorized: true)")
        XCTAssertFalse(admin.description.contains("s3cr3t"), "token must not leak")
    }

    // MARK: - Builder descriptions render the built model's JSON (faithful round-trip)

    func testRequestPatternBuilderDescriptionIsPatternJSON() throws {
        let builder = getRequestedFor(urlEqualTo("/x")).withHeader("H", equalTo("v"))
        XCTAssertTrue(builder.description.hasPrefix("{"))
        XCTAssertEqual(try WireMockFixture.decode(RequestPattern.self, builder.description), builder.pattern)
    }

    func testResponseDefinitionBuilderDescriptionIsDefinitionJSON() throws {
        let builder = ok("hi").withHeader("X-A", "y").withFixedDelay(50)
        XCTAssertTrue(builder.description.hasPrefix("{"))
        XCTAssertEqual(try WireMockFixture.decode(ResponseDefinition.self, builder.description), builder.definition)
    }

    func testWebhookDefinitionDescriptionIsListenerJSON() throws {
        let webhook = WebhookDefinition(method: .post, url: "http://cb", body: "ping")
        XCTAssertTrue(webhook.description.contains("\"webhook\""))
        XCTAssertEqual(try WireMockFixture.decode(ServeEventListenerDefinition.self, webhook.description),
                       webhook.asServeEventListener())
    }
}
