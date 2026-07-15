import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pure (hermetic, no-server) decoding tests for the model types, driven from the
/// exact JSON shapes the WireMock server emits (captured from the live 3.13.2
/// server). The matching live-server round-trips live in `ModelDecodingLiveTests`.
final class ModelDecodingTests: XCTestCase {

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
        let req = try WireMockFixture.decode(LoggedRequest.self, raw)
        XCTAssertEqual(req.url, "/form")
        XCTAssertEqual(req.absoluteUrl, "http://localhost:8080/form")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.scheme, "http")
        XCTAssertEqual(req.host, "localhost")
        XCTAssertEqual(req.port, 8080)
        XCTAssertEqual(req.clientIp, "127.0.0.1")
        XCTAssertEqual(req.headers?["Content-Type"], .single("application/x-www-form-urlencoded"))
        XCTAssertEqual(req.cookies?["session"], "abc")
        XCTAssertEqual(req.body, "name=bob&age=3")
        XCTAssertEqual(req.bodyAsBase64, "bmFtZT1ib2ImYWdlPTM=")
        XCTAssertEqual(req.loggedDate, 1783933594444)
        XCTAssertEqual(req.loggedDateString, "2026-07-13T00:00:00Z")
        XCTAssertEqual(req.queryParams?.objectValue?.isEmpty, true)
        XCTAssertEqual(req.browserProxyRequest, false)
        // The wire key is "protocol"; it maps to protocolVersion.
        XCTAssertEqual(req.protocolVersion, "HTTP/1.1")
        // formParams is nested JSON: name -> { key, values: [...] }.
        let name = req.formParams?.objectValue?["name"]?.objectValue
        XCTAssertEqual(name?["values"]?.arrayValue?.first, "bob")
    }

    func testLoggedRequestMultiValueHeaderDecodes() throws {
        let raw = #"{ "url": "/x", "method": "GET", "headers": { "Accept": ["a", "b"] } }"#
        let req = try WireMockFixture.decode(LoggedRequest.self, raw)
        XCTAssertEqual(req.headers?["Accept"], .multiple(["a", "b"]))
    }

    // MARK: - ServeEvent

    func testServeEventWasMatchedDecodes() throws {
        let matched = #"{ "id": "11111111-1111-1111-1111-111111111111", "request": { "url": "/a", "method": "GET" }, "wasMatched": true }"#
        let event = try WireMockFixture.decode(ServeEvent.self, matched)
        XCTAssertEqual(event.wasMatched, true)
        XCTAssertEqual(event.request.url, "/a")
        XCTAssertEqual(event.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

        let unmatched = #"{ "request": { "url": "/b", "method": "GET" }, "wasMatched": false }"#
        XCTAssertEqual(try WireMockFixture.decode(ServeEvent.self, unmatched).wasMatched, false)
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
        let miss = try WireMockFixture.decode(NearMiss.self, raw)
        XCTAssertEqual(miss.request?.url, "/expectd")
        XCTAssertEqual(miss.requestPattern?.url, "/expected")
        // Pure-decode test with a literal input → pin the exact value, not a range.
        let distance = try XCTUnwrap(miss.matchResult?.distance)
        XCTAssertEqual(distance, 0.0284900284900, accuracy: 1e-12)
    }

    // MARK: - DelayDistribution

    func testDelayDistributionDecodesEachVariant() throws {
        if case .uniform(let lower, let upper) = try WireMockFixture.decode(DelayDistribution.self, #"{"type":"uniform","lower":5,"upper":9}"#) {
            XCTAssertEqual(lower, 5); XCTAssertEqual(upper, 9)
        } else { XCTFail("expected uniform") }

        if case .lognormal(let median, let sigma, let maxValue) = try WireMockFixture.decode(DelayDistribution.self, #"{"type":"lognormal","median":90,"sigma":0.1}"#) {
            XCTAssertEqual(median, 90); XCTAssertEqual(sigma, 0.1); XCTAssertNil(maxValue)
        } else { XCTFail("expected lognormal") }

        // An unknown type must be preserved, not throw.
        if case .other(let raw) = try WireMockFixture.decode(DelayDistribution.self, #"{"type":"exponential","mean":10}"#) {
            XCTAssertEqual(raw.objectValue?["mean"], 10)
        } else { XCTFail("expected other") }
    }

    // MARK: - HeaderValue

    func testHeaderValueDecodesSingleAndMultiple() throws {
        XCTAssertEqual(try WireMockFixture.decode(HeaderValue.self, #""text/plain""#), .single("text/plain"))
        XCTAssertEqual(try WireMockFixture.decode(HeaderValue.self, #"["a","b"]"#), .multiple(["a", "b"]))
    }

    // MARK: - Scenario

    func testScenarioDecodesPossibleStates() throws {
        let raw = #"{ "id": "s", "name": "flow", "state": "Started", "possibleStates": ["Started", "next"] }"#
        let scenario = try WireMockFixture.decode(Scenario.self, raw)
        XCTAssertEqual(scenario.name, "flow")
        XCTAssertEqual(scenario.state, "Started")
        XCTAssertEqual(scenario.possibleStates, ["Started", "next"])
    }

    // MARK: - Acceptance coverage: journal response/timing, multi-value cookie, diffs

    func testLoggedRequestDecodesMultiValueCookie() throws {
        // A cookie name may repeat → the server emits an array; single stays a string.
        let raw = #"{"url":"/x","method":"GET","cookies":{"single":"a","multi":["x","y"]}}"#
        let request = try WireMockFixture.decode(LoggedRequest.self, raw)
        XCTAssertEqual(request.cookies?["single"], .single("a"))
        XCTAssertEqual(request.cookies?["multi"], .multiple(["x", "y"]))
    }

    func testServeEventDecodesResponseAndTiming() throws {
        let raw = #"{"request":{"url":"/x","method":"GET"},"response":{"status":201,"body":"hi","headers":{"X-A":"1"}},"timing":{"serveTime":5,"totalTime":7}}"#
        let event = try WireMockFixture.decode(ServeEvent.self, raw)
        XCTAssertEqual(event.response?.status, 201)
        XCTAssertEqual(event.response?.body, "hi")
        XCTAssertEqual(event.response?.headers?["X-A"], .single("1"))
        XCTAssertEqual(event.timing?.serveTime, 5)
        XCTAssertEqual(event.timing?.totalTime, 7)
    }

    func testMatchResultDecodesDiffDescriptions() throws {
        let raw = #"{"distance":0.3,"diffDescriptions":[{"expected":"/a","actual":"/b","errorMessage":"URL does not match"}]}"#
        let result = try WireMockFixture.decode(MatchResult.self, raw)
        XCTAssertEqual(result.distance, 0.3)
        XCTAssertEqual(result.diffDescriptions?.first?.expected, "/a")
        XCTAssertEqual(result.diffDescriptions?.first?.actual, "/b")
        XCTAssertEqual(result.diffDescriptions?.first?.errorMessage, "URL does not match")
    }

    // MARK: - SubEvents (the diagnostic diff report the 3.13.2 server attaches)

    func testServeEventDecodesSubEvents() throws {
        // Shape the live server emits on an unmatched request (GET /__admin/requests).
        let raw = #"""
        {
          "request": { "url": "/x", "method": "GET" },
          "wasMatched": false,
          "subEvents": [
            { "type": "REQUEST_NOT_MATCHED", "timeOffsetNanos": 169333,
              "data": { "status": 404, "contentType": "text/plain", "report": "Request was not matched" } }
          ]
        }
        """#
        let event = try WireMockFixture.decode(ServeEvent.self, raw)
        let sub = try XCTUnwrap(event.subEvents?.first)
        XCTAssertEqual(sub.type, "REQUEST_NOT_MATCHED")
        XCTAssertEqual(sub.timeOffsetNanos, 169333)
        XCTAssertEqual(sub.data?.objectValue?["status"], 404)
        XCTAssertEqual(sub.data?.objectValue?["report"], "Request was not matched")
    }

    func testMatchResultDecodesSubEvents() throws {
        let raw = #"{"distance":0.2,"diffDescriptions":[],"subEvents":[{"type":"REQUEST_NOT_MATCHED","data":{"report":"x"}}]}"#
        let result = try WireMockFixture.decode(MatchResult.self, raw)
        XCTAssertEqual(result.distance, 0.2)
        XCTAssertEqual(result.subEvents?.first?.type, "REQUEST_NOT_MATCHED")
        XCTAssertEqual(result.subEvents?.first?.data?.objectValue?["report"], "x")
    }

    // MARK: - SnapshotResult (mappings vs ids output formats)

    func testSnapshotResultDecodesMappingsAndIds() throws {
        // Default output: a mappings array.
        let mappingsForm = try WireMockFixture.decode(SnapshotResult.self, #"{"mappings":[{"request":{"url":"/a","method":"GET"},"response":{"status":200}}]}"#)
        XCTAssertEqual(mappingsForm.mappings?.count, 1)
        XCTAssertNil(mappingsForm.ids)

        // outputFormat="ids": an ids array instead (previously silently dropped).
        let idsForm = try WireMockFixture.decode(SnapshotResult.self, #"{"ids":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"]}"#)
        XCTAssertEqual(idsForm.ids?.count, 2)
        XCTAssertEqual(idsForm.ids?.first, "11111111-1111-1111-1111-111111111111")
        XCTAssertNil(idsForm.mappings)
    }
}
