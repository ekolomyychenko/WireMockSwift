import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Decoding tests for the model types, driven from the exact JSON shapes the
/// WireMock server emits (captured from the live 3.13.2 server). Split into pure
/// decoding (no server) and a few live-server round-trips that assert the same
/// fields survive real traffic.
final class ModelDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - LoggedRequest

    func testLoggedRequestDecodesAllFields() throws {
        // Shape captured from GET /__admin/requests on the live server.
        let raw = #"""
        {
          "url": "/form",
          "absoluteUrl": "http://localhost:8080/form",
          "method": "POST",
          "scheme": "http",
          "host": "localhost",
          "port": 8080,
          "clientIp": "127.0.0.1",
          "headers": { "Content-Type": "application/x-www-form-urlencoded" },
          "cookies": { "session": "abc" },
          "body": "name=bob&age=3",
          "bodyAsBase64": "bmFtZT1ib2ImYWdlPTM=",
          "loggedDate": 1783933594444,
          "loggedDateString": "2026-07-13T00:00:00Z",
          "queryParams": {},
          "formParams": { "name": { "key": "name", "values": ["bob"] } },
          "browserProxyRequest": false,
          "protocol": "HTTP/1.1"
        }
        """#
        let req = try decode(LoggedRequest.self, raw)
        XCTAssertEqual(req.url, "/form")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.scheme, "http")
        XCTAssertEqual(req.port, 8080)
        XCTAssertEqual(req.clientIp, "127.0.0.1")
        XCTAssertEqual(req.cookies?["session"], "abc")
        XCTAssertEqual(req.body, "name=bob&age=3")
        XCTAssertEqual(req.loggedDate, 1783933594444)
        XCTAssertEqual(req.browserProxyRequest, false)
        // The wire key is "protocol"; it maps to protocolVersion.
        XCTAssertEqual(req.protocolVersion, "HTTP/1.1")
        // formParams is nested JSON: name -> { key, values: [...] }.
        let name = req.formParams?.objectValue?["name"]?.objectValue
        XCTAssertEqual(name?["values"]?.arrayValue?.first, "bob")
    }

    func testLoggedRequestMultiValueHeaderDecodes() throws {
        let raw = #"{ "url": "/x", "method": "GET", "headers": { "Accept": ["a", "b"] } }"#
        let req = try decode(LoggedRequest.self, raw)
        XCTAssertEqual(req.headers?["Accept"], .multiple(["a", "b"]))
    }

    // MARK: - ServeEvent

    func testServeEventWasMatchedDecodes() throws {
        let matched = #"{ "id": "11111111-1111-1111-1111-111111111111", "request": { "url": "/a", "method": "GET" }, "wasMatched": true }"#
        let event = try decode(ServeEvent.self, matched)
        XCTAssertEqual(event.wasMatched, true)
        XCTAssertEqual(event.request.url, "/a")
        XCTAssertEqual(event.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

        let unmatched = #"{ "request": { "url": "/b", "method": "GET" }, "wasMatched": false }"#
        XCTAssertEqual(try decode(ServeEvent.self, unmatched).wasMatched, false)
    }

    // MARK: - NearMiss / MatchResult

    func testNearMissDistanceDecodes() throws {
        let raw = #"""
        {
          "request": { "url": "/expectd", "method": "GET" },
          "requestPattern": { "method": "GET", "url": "/expected" },
          "matchResult": { "distance": 0.0284900284900 }
        }
        """#
        let miss = try decode(NearMiss.self, raw)
        XCTAssertEqual(miss.request?.url, "/expectd")
        XCTAssertEqual(miss.requestPattern?.url, "/expected")
        let distance = try XCTUnwrap(miss.matchResult?.distance)
        XCTAssertGreaterThan(distance, 0)
        XCTAssertLessThan(distance, 1)
    }

    // MARK: - DelayDistribution

    func testDelayDistributionDecodesEachVariant() throws {
        if case .uniform(let lower, let upper) = try decode(DelayDistribution.self, #"{"type":"uniform","lower":5,"upper":9}"#) {
            XCTAssertEqual(lower, 5); XCTAssertEqual(upper, 9)
        } else { XCTFail("expected uniform") }

        if case .lognormal(let median, let sigma) = try decode(DelayDistribution.self, #"{"type":"lognormal","median":90,"sigma":0.1}"#) {
            XCTAssertEqual(median, 90); XCTAssertEqual(sigma, 0.1)
        } else { XCTFail("expected lognormal") }

        // An unknown type must be preserved, not throw.
        if case .other(let raw) = try decode(DelayDistribution.self, #"{"type":"exponential","mean":10}"#) {
            XCTAssertEqual(raw.objectValue?["mean"], 10)
        } else { XCTFail("expected other") }
    }

    // MARK: - HeaderValue

    func testHeaderValueDecodesSingleAndMultiple() throws {
        XCTAssertEqual(try decode(HeaderValue.self, #""text/plain""#), .single("text/plain"))
        XCTAssertEqual(try decode(HeaderValue.self, #"["a","b"]"#), .multiple(["a", "b"]))
    }

    // MARK: - Scenario

    func testScenarioDecodesPossibleStates() throws {
        let raw = #"{ "id": "s", "name": "flow", "state": "Started", "possibleStates": ["Started", "next"] }"#
        let scenario = try decode(Scenario.self, raw)
        XCTAssertEqual(scenario.name, "flow")
        XCTAssertEqual(scenario.state, "Started")
        XCTAssertEqual(scenario.possibleStates, ["Started", "next"])
    }

    // MARK: - Live decode round-trips

    func testLiveLoggedRequestFormParamsAndProtocol() async throws {
        let wireMock = try await WireMockFixture.clientOrSkip()
        try await wireMock.stubFor(post(urlPathEqualTo("/form")).willReturn(ok()))
        try await WireMockFixture.hit(
            "form", method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("name=bob&age=3".utf8)
        )
        let logged = try await wireMock.findAll(postRequestedFor(urlPathEqualTo("/form")))
        let req = try XCTUnwrap(logged.first)
        XCTAssertEqual(req.method, "POST")
        // protocol/browserProxyRequest are populated by the server.
        XCTAssertEqual(req.protocolVersion, "HTTP/1.1")
        XCTAssertEqual(req.browserProxyRequest, false)
        // formParams should include the posted fields.
        let formName = req.formParams?.objectValue?["name"]?.objectValue?["values"]?.arrayValue?.first
        XCTAssertEqual(formName, "bob")
    }

    func testLiveServeEventWasMatchedTrueAndFalse() async throws {
        let wireMock = try await WireMockFixture.clientOrSkip()
        try await wireMock.stubFor(get(urlEqualTo("/hit")).willReturn(ok()))
        _ = try await WireMockFixture.hit("hit")      // matched
        _ = try await WireMockFixture.hit("nope")     // unmatched

        let events = try await wireMock.getAllServeEvents()
        let hit = try XCTUnwrap(events.first { $0.request.url == "/hit" })
        let miss = try XCTUnwrap(events.first { $0.request.url == "/nope" })
        XCTAssertEqual(hit.wasMatched, true)
        XCTAssertEqual(miss.wasMatched, false)
    }

    func testLiveNearMissDistanceIsPositive() async throws {
        let wireMock = try await WireMockFixture.clientOrSkip()
        try await wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        _ = try await WireMockFixture.hit("expectd")  // near miss

        let misses = try await wireMock.findNearMissesForAllUnmatched()
        let miss = try XCTUnwrap(misses.first)
        let distance = try XCTUnwrap(miss.matchResult?.distance)
        XCTAssertGreaterThan(distance, 0)
    }
}
