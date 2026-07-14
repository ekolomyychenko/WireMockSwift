import XCTest
@testable import WireMock

/// Verifies the `description`/`toString` representations used for Allure logging:
/// leaf types render as their bare value, and container types render as their
/// WireMock JSON (mirroring Java `toString()`). Correctness for containers is
/// proven by a round-trip: the description must be valid JSON that decodes back
/// into an equal object.
final class DescriptionTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// The description is complete, valid JSON that reconstructs the same value.
    private func assertRoundTrips<T: Codable & Hashable & CustomStringConvertible>(_ value: T,
                                                                                   file: StaticString = #filePath,
                                                                                   line: UInt = #line) throws {
        let again = try decode(T.self, value.description)
        XCTAssertEqual(value, again, "description is not faithful JSON for \(T.self)", file: file, line: line)
    }

    // MARK: - Leaf types render as bare values

    func testHTTPMethodDescription() {
        XCTAssertEqual(HTTPMethod.get.description, "GET")
        XCTAssertEqual(HTTPMethod("REPORT").description, "REPORT")
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

    func testCountMatchingStrategyDescription() {
        XCTAssertEqual(CountMatchingStrategy.exactly(3).description, "exactly 3")
        XCTAssertEqual("\(CountMatchingStrategy.lessThan(4))", "less than 4")
        XCTAssertEqual("\(CountMatchingStrategy.moreThanOrExactly(1))", "more than or exactly 1")
    }

    func testUrlPatternDescription() {
        XCTAssertEqual(urlPathEqualTo("/things").description, "urlPath=/things")
        XCTAssertEqual(urlEqualTo("/x?q=1").description, "url=/x?q=1")
        XCTAssertEqual(anyUrl.description, "anyUrl")
    }

    func testAuthorizationDescriptionMasksSecret() {
        let desc = AdminAuthorization.basic(username: "admin", password: "s3cr3t").description
        XCTAssertFalse(desc.contains("s3cr3t"), "password must not leak: \(desc)")
        XCTAssertTrue(desc.contains("admin") && desc.contains("***"))
        XCTAssertFalse(AdminAuthorization.bearer(token: "tok123").description.contains("tok123"))
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
        let logged = try decode(LoggedRequest.self, #"""
        {"url":"/form","method":"POST","headers":{"Content-Type":"application/json"},
         "body":"{}","queryParams":{},"protocol":"HTTP/1.1"}
        """#)
        try assertRoundTrips(logged)
    }

    func testServeEventAndNearMissDescriptionRoundTrip() throws {
        let event = try decode(ServeEvent.self, #"""
        {"request":{"url":"/x","method":"GET"},"wasMatched":true}
        """#)
        try assertRoundTrips(event)

        let nearMiss = try decode(NearMiss.self, #"""
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
}
