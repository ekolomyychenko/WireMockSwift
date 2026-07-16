import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unit coverage for the pre-release parity/ergonomics additions: `okJson`,
/// `withBody(Data)`, `never()`, the `matchingJsonSchema(raw:)` and date-matcher
/// free functions, the `aMultipart()` builder, `register(raw:)` validation,
/// `pathSegment` traversal rejection, `callAsync` cancellation, and the
/// `VerificationError` near-miss diff rendering. No server required.
final class ReleasePolishTests: XCTestCase {

    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    // MARK: Response builder

    func testOkJsonAliasesOkForJson() throws {
        // The Java-named `okJson` must serialise identically to `okForJson`.
        let viaAlias = okJson(["id": 1]).definition
        let viaOriginal = okForJson(["id": 1]).definition
        XCTAssertEqual(try json(viaAlias), try json(viaOriginal))
    }

    func testWithBodyDataEncodesBase64() throws {
        let response = aResponse().withStatus(200).withBody(Data("hi".utf8)).definition
        XCTAssertEqual(response.base64Body, "aGk=")   // base64("hi")
        XCTAssertNil(response.body, "binary body must go through base64Body, not body")
    }

    // MARK: Verification strategy

    func testNeverIsExactlyZero() {
        XCTAssertTrue(never().isSatisfied(by: 0))
        XCTAssertFalse(never().isSatisfied(by: 1))
    }

    func testIsShortfallOnlyForTooFew() {
        XCTAssertTrue(CountMatchingStrategy.exactly(2).isShortfall(1))
        XCTAssertFalse(CountMatchingStrategy.exactly(2).isShortfall(3))   // too many, not a shortfall
        XCTAssertTrue(CountMatchingStrategy.moreThanOrExactly(1).isShortfall(0))
        XCTAssertFalse(CountMatchingStrategy.lessThan(2).isShortfall(5))  // over-count can't be helped by more requests
    }

    // MARK: Matchers

    func testMatchingJsonSchemaRawFreeFunction() throws {
        let pattern = try matchingJsonSchema(raw: #"{"type":"object"}"#)
        let expected: JSONValue = ["matchesJsonSchema": ["type": "object"]]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testMatchingJsonSchemaRawFreeFunctionRejectsBadJSON() {
        XCTAssertThrowsError(try matchingJsonSchema(raw: "{ not json"))
    }

    func testDateMatcherFreeFunctionsForwardOptions() throws {
        // The free functions must carry every option through to the same shape
        // the static factories produce.
        let free = before("2021-01-01T00:00:00Z", expectedOffset: 3, expectedOffsetUnit: .days)
        let factory = StringValuePattern.before("2021-01-01T00:00:00Z", expectedOffset: 3, expectedOffsetUnit: .days)
        XCTAssertEqual(try json(free), try json(factory))

        let expected: JSONValue = [
            "before": "2021-01-01T00:00:00Z",
            "expectedOffset": 3,
            "expectedOffsetUnit": "DAYS"
        ]
        XCTAssertEqual(try json(free), expected)
    }

    // MARK: Multipart builder

    func testAMultipartBuilderEncodesEveryField() throws {
        let part = aMultipart("info")
            .withFileName("data.json")
            .matchingType(.all)
            .withHeader("Content-Type", equalTo("application/json"))
            .withBody(matchingJsonPath("$.name"))
            .build()

        let expected: JSONValue = [
            "name": "info",
            "fileName": "data.json",
            "matchingType": "ALL",
            "headers": ["Content-Type": ["equalTo": "application/json"]],
            "bodyPatterns": [["matchesJsonPath": "$.name"]]
        ]
        XCTAssertEqual(try json(part), expected)
    }

    func testWithMultipartRequestBodyAcceptsBuilder() throws {
        // The builder overload must produce the same stub as passing a struct.
        let viaBuilder = post(urlPathEqualTo("/u"))
            .withMultipartRequestBody(aMultipart("f").withBody(containing("x")))
            .willReturn(ok()).build()
        let viaStruct = post(urlPathEqualTo("/u"))
            .withMultipartRequestBody(MultipartValuePattern(name: "f", bodyPatterns: [containing("x")]))
            .willReturn(ok()).build()
        XCTAssertEqual(try json(viaBuilder), try json(viaStruct))
    }

    // MARK: register(raw:) validation

    func testRegisterRawRejectsJSONFragment() {
        // A bare fragment must fail locally (before any network) with a clear
        // message, not as an opaque server 422.
        let wireMock = WireMock(baseURL: URL(string: "http://127.0.0.1:1")!)
        XCTAssertThrowsError(try wireMock.register(raw: "\"just a string\"")) { error in
            guard case WireMockError.decodingFailed(let message) = error else {
                return XCTFail("expected decodingFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("JSON object"), message)
        }
        XCTAssertThrowsError(try wireMock.register(raw: "123"))
    }

    // MARK: Path-segment traversal guard

    func testPathSegmentRejectsTraversal() {
        XCTAssertThrowsError(try AdminClient.pathSegment(".."))
        XCTAssertThrowsError(try AdminClient.pathSegment("."))
        XCTAssertThrowsError(try AdminClient.pathSegment(""))
        XCTAssertEqual(try AdminClient.pathSegment("normal.json"), "normal.json")
    }

    // MARK: callAsync cancellation

    func testCallAsyncHonoursCancellation() async {
        let wireMock = WireMock(baseURL: URL(string: "http://127.0.0.1:8080")!)
        let task = Task { () -> Int in
            // Let the cancel below land first; then callAsync's up-front
            // checkCancellation() should throw rather than start the blocking call.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return try await wireMock.callAsync { _ in 1 }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: VerificationError near-miss rendering

    private func nearMiss(distance: Double, _ diffs: [DiffDescription]) -> NearMiss {
        NearMiss(request: nil, stubMapping: nil, requestPattern: nil,
                 matchResult: MatchResult(distance: distance, diffDescriptions: diffs, subEvents: nil))
    }

    func testVerificationErrorRendersClosestDiff() {
        let closest = nearMiss(distance: 0.1, [DiffDescription(expected: "/a", actual: "/b", errorMessage: nil)])
        let farther = nearMiss(distance: 0.9, [DiffDescription(expected: "/z", actual: "/b", errorMessage: nil)])
        let error = VerificationError(expected: "exactly 1", actual: 0, nearMisses: [farther, closest])
        let text = error.description
        XCTAssertTrue(text.contains("Closest match"), text)
        XCTAssertTrue(text.contains("expected /a but was /b"), text)      // smallest distance wins
        XCTAssertFalse(text.contains("/z"), "should render only the closest near miss")
    }

    func testVerificationErrorPrefersErrorMessage() {
        let nm = nearMiss(distance: 0.1, [DiffDescription(expected: nil, actual: nil, errorMessage: "URL does not match")])
        XCTAssertTrue(VerificationError(expected: "exactly 1", actual: 0, nearMisses: [nm])
            .description.contains("- URL does not match"))
    }

    func testVerificationErrorSummarisesClosestRequestWhenNoDiffs() throws {
        // 3.13.2's request-pattern near misses have empty diffDescriptions, so
        // the closest actual request is summarised instead.
        let request = try WireMockFixture.decode(LoggedRequest.self, #"{"method":"GET","url":"/actual"}"#)
        let nm = NearMiss(request: request, stubMapping: nil, requestPattern: nil,
                          matchResult: MatchResult(distance: 0.2, diffDescriptions: [], subEvents: nil))
        let text = VerificationError(expected: "exactly 1", actual: 0, nearMisses: [nm]).description
        XCTAssertTrue(text.contains("closest request was: GET /actual"), text)
        // W1: the raw score is labelled ("match distance … — lower is closer"), not a
        // bare unitless number.
        XCTAssertTrue(text.contains("match distance 0.2"), text)
        XCTAssertTrue(text.contains("lower is closer"), text)
    }

    func testVerificationErrorWithoutNearMissesIsBare() {
        // A "too many" failure carries no near misses → no diff block.
        let error = VerificationError(expected: "exactly 1", actual: 3)
        XCTAssertEqual(error.description, "Expected exactly 1 matching request(s) but found 3")
    }
}

/// Live-server coverage for the additions that touch the wire: `verify` near-miss
/// diagnostics, `countStubMappings`, the raw-admin escape hatch, and a binary
/// `withBody(Data)` round-trip.
final class ReleasePolishIntegrationTests: WireMockIntegrationCase {

    func testVerifyFailureCarriesNearMissDiff() throws {
        try wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        // Send a request that does NOT match, so the journal holds a near miss.
        WireMockFixture.assertMiss(try WireMockFixture.hit("actual"))

        XCTAssertThrowsError(try wireMock.verify(getRequestedFor(urlEqualTo("/expected")))) { error in
            guard let verification = error as? VerificationError else {
                return XCTFail("expected VerificationError, got \(error)")
            }
            XCTAssertEqual(verification.actual, 0)
            XCTAssertFalse(verification.nearMisses.isEmpty, "a shortfall should attach near misses")
            XCTAssertTrue(verification.description.contains("Closest match"),
                          "description should include the near-miss report:\n\(verification.description)")
            XCTAssertTrue(verification.description.contains("closest request was: GET /actual"),
                          "description should name the closest actual request:\n\(verification.description)")
        }
    }

    func testCountStubMappingsUsesServerTotal() throws {
        try wireMock.removeAllMappings()
        try wireMock.stubFor(get(urlEqualTo("/a")).willReturn(ok()))
        try wireMock.stubFor(get(urlEqualTo("/b")).willReturn(ok()))
        try wireMock.stubFor(get(urlEqualTo("/c")).willReturn(ok()))
        XCTAssertEqual(try wireMock.countStubMappings(), 3)
    }

    func testRawRequestReachesUnmodelledEndpoint() throws {
        // The escape hatch must reach an admin endpoint the typed API doesn't wrap.
        let data = try wireMock.admin.rawRequest("GET", "health")
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("healthy"), body)
    }

    func testWithBodyDataRoundTripsBinary() throws {
        let payload = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        try wireMock.stubFor(get(urlEqualTo("/bin")).willReturn(aResponse().withStatus(200).withBody(payload)))
        let (data, response) = try WireMockFixture.hit("bin")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, payload, "binary body should survive the base64 round trip")
    }
}
