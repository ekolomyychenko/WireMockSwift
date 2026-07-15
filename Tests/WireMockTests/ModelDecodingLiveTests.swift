import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live-server round-trips that assert the model types decode the SAME fields off
/// real 3.13.2 traffic that the pure-JSON tests in `ModelDecodingTests` decode off
/// captured shapes. Split out from that file so the pure-decode suite stays fully
/// hermetic (runnable without a server), and so these inherit the shared
/// reset-in-setUp / clean-up-in-tearDown lifecycle instead of leaking stubs.
final class ModelDecodingLiveTests: WireMockIntegrationCase {

    func testLiveLoggedRequestFormParamsAndProtocol() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/form")).willReturn(ok()))
        try WireMockFixture.hit(
            "form", method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("name=bob&age=3".utf8)
        )
        let logged = try wireMock.findAll(postRequestedFor(urlPathEqualTo("/form")))
        let req = try XCTUnwrap(logged.first)
        XCTAssertEqual(req.method, "POST")
        // protocol/browserProxyRequest are populated by the server.
        XCTAssertEqual(req.protocolVersion, "HTTP/1.1")
        XCTAssertEqual(req.browserProxyRequest, false)
        // formParams should include the posted fields.
        let formName = req.formParams?.objectValue?["name"]?.objectValue?["values"]?.arrayValue?.first
        XCTAssertEqual(formName, "bob")
    }

    func testLiveServeEventWasMatchedTrueAndFalse() throws {
        try wireMock.stubFor(get(urlEqualTo("/hit")).willReturn(ok()))
        _ = try WireMockFixture.hit("hit")      // matched
        _ = try WireMockFixture.hit("nope")     // unmatched

        let events = try wireMock.getAllServeEvents()
        let hit = try XCTUnwrap(events.first { $0.request.url == "/hit" })
        let miss = try XCTUnwrap(events.first { $0.request.url == "/nope" })
        XCTAssertEqual(hit.wasMatched, true)
        XCTAssertEqual(miss.wasMatched, false)
    }

    func testLiveNearMissDistanceIsPositive() throws {
        try wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        _ = try WireMockFixture.hit("expectd")  // near miss

        let misses = try wireMock.findNearMissesForAllUnmatched()
        let miss = try XCTUnwrap(misses.first)
        let distance = try XCTUnwrap(miss.matchResult?.distance)
        XCTAssertGreaterThan(distance, 0)
    }

    func testLiveServeEventCarriesSubEventsForUnmatched() throws {
        // End-to-end proof (not just hardcoded-JSON decode): the real 3.13.2
        // server attaches a REQUEST_NOT_MATCHED subEvent to an unmatched serve
        // event, and getAllServeEvents() decodes it.
        _ = try WireMockFixture.hit("totally-unmatched-xyz")
        let events = try wireMock.getAllServeEvents()
        let unmatched = try XCTUnwrap(events.first { $0.request.url == "/totally-unmatched-xyz" })
        let sub = try XCTUnwrap(unmatched.subEvents?.first, "server should attach a subEvent to an unmatched event")
        XCTAssertEqual(sub.type, "REQUEST_NOT_MATCHED")
        XCTAssertNotNil(sub.data, "the subEvent should carry a diff/report payload")
    }
}
