import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live-server coverage of the `WireMock` facade admin operations that were
/// untested: mapping CRUD, serve-event lookup/removal, near-miss queries,
/// explicit scenario state, bulk import, exhaustive count strategies (including
/// failures), and global-settings round-trips.
final class FacadeIntegrationTests: XCTestCase {
    private var wireMock: WireMock!

    override func setUpWithError() throws {
        wireMock = try WireMockFixture.clientOrSkip()
    }

    override func tearDownWithError() throws {
        if wireMock != nil {
            try? wireMock.setGlobalFixedDelay(0)
            try? wireMock.resetAll()
        }
    }

    // MARK: Mapping CRUD

    func testGetStubMapping() throws {
        let created = try wireMock.stubFor(get(urlEqualTo("/g")).willReturn(ok("hi")))
        let id = try XCTUnwrap(created.id)
        let fetched = try wireMock.getStubMapping(id: id)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.request.url, "/g")
        XCTAssertEqual(fetched.response.body, "hi")
    }

    func testEditStubMapping() throws {
        let created = try wireMock.stubFor(get(urlEqualTo("/e")).willReturn(ok("before")))
        let id = try XCTUnwrap(created.id)

        var updated = created
        updated.response = ok("after").definition
        let result = try wireMock.editStubMapping(id: id, updated)
        XCTAssertEqual(result.id, id)

        let (data, _) = try WireMockFixture.hit("e")
        XCTAssertEqual(String(data: data, encoding: .utf8), "after", "edit should replace the served body")
    }

    func testRemoveAllMappings() throws {
        try wireMock.stubFor(get(urlEqualTo("/a")).willReturn(ok()))
        try wireMock.stubFor(get(urlEqualTo("/b")).willReturn(ok()))
        let before = try wireMock.listAllStubMappings()
        XCTAssertFalse(before.isEmpty)

        try wireMock.removeAllMappings()
        let after = try wireMock.listAllStubMappings()
        XCTAssertTrue(after.isEmpty)
    }

    func testResetToDefaultMappings() throws {
        // With no persisted baseline on disk, resetToDefaultMappings clears the
        // in-memory stubs (reloads the empty default set) without throwing.
        try wireMock.stubFor(get(urlEqualTo("/transient")).willReturn(ok()))
        try wireMock.resetToDefaultMappings()
        let all = try wireMock.listAllStubMappings()
        XCTAssertFalse(all.contains { $0.request.url == "/transient" },
                       "transient stub should be gone after resetToDefaultMappings")
    }

    // MARK: Serve events

    func testGetAndRemoveServeEvent() throws {
        try wireMock.stubFor(get(urlEqualTo("/se")).willReturn(ok()))
        _ = try WireMockFixture.hit("se")

        let events = try wireMock.getAllServeEvents()
        let event = try XCTUnwrap(events.first { $0.request.url == "/se" })
        let id = try XCTUnwrap(event.id)

        let fetched = try wireMock.getServeEvent(id: id)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.request.url, "/se")

        try wireMock.removeServeEvent(id: id)
        let remaining = try wireMock.getAllServeEvents()
        XCTAssertFalse(remaining.contains { $0.id == id }, "serve event should be removed")
    }

    // MARK: Near misses

    func testFindNearMissesForRequest() throws {
        try wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        _ = try WireMockFixture.hit("expectd") // near miss
        let unmatched = try wireMock.getUnmatchedRequests()
        let request = try XCTUnwrap(unmatched.first)

        let misses = try wireMock.findNearMisses(for: request)
        XCTAssertFalse(misses.isEmpty)
        XCTAssertNotNil(misses.first?.matchResult?.distance)
    }

    func testFindNearMissesForPattern() throws {
        try wireMock.stubFor(get(urlEqualTo("/exact")).willReturn(ok()))
        _ = try WireMockFixture.hit("exact")

        // A pattern for a slightly different URL should report the served
        // request as a near miss.
        let misses = try wireMock.findNearMisses(for: getRequestedFor(urlEqualTo("/exacts")))
        XCTAssertFalse(misses.isEmpty)
        XCTAssertNotNil(misses.first?.request)
    }

    // MARK: Scenarios

    func testSetScenarioStateExplicitly() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/sc")).inScenario("flow").whenScenarioStateIs("Started").willReturn(ok("first"))
        )
        try wireMock.stubFor(
            get(urlEqualTo("/sc")).inScenario("flow").whenScenarioStateIs("jumped").willReturn(ok("jumped"))
        )
        // Jump straight to a non-initial state.
        try wireMock.setScenarioState(name: "flow", state: "jumped")
        let (data, _) = try WireMockFixture.hit("sc")
        XCTAssertEqual(String(data: data, encoding: .utf8), "jumped")

        let scenarios = try wireMock.getAllScenarios()
        let scenario = try XCTUnwrap(scenarios.first { $0.name == "flow" })
        XCTAssertEqual(scenario.state, "jumped")
        // possibleStates should include both declared states.
        let possible = Set(scenario.possibleStates ?? [])
        XCTAssertTrue(possible.contains("Started"))
        XCTAssertTrue(possible.contains("jumped"))
    }

    // MARK: Bulk import (multiple)

    func testImportMultipleMappings() throws {
        let stubs = [
            get(urlEqualTo("/one")).willReturn(ok("1")).build(),
            get(urlEqualTo("/two")).willReturn(ok("2")).build(),
            get(urlEqualTo("/three")).willReturn(ok("3")).build(),
        ]
        try wireMock.importMappings(stubs)
        for (path, expected) in [("one", "1"), ("two", "2"), ("three", "3")] {
            let (data, _) = try WireMockFixture.hit(path)
            XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        }
    }

    // MARK: Count strategies (exhaustive, including failures)

    func testCountStrategiesExhaustive() throws {
        try wireMock.stubFor(get(urlEqualTo("/c")).willReturn(ok()))
        for _ in 0..<3 { _ = try WireMockFixture.hit("c") }
        let builder = getRequestedFor(urlEqualTo("/c"))

        // Passing cases.
        try wireMock.verify(.exactly(3), builder)
        try wireMock.verify(.lessThan(4), builder)
        try wireMock.verify(.lessThanOrExactly(3), builder)
        try wireMock.verify(.moreThan(2), builder)
        try wireMock.verify(.moreThanOrExactly(3), builder)

        // Failing cases: each must throw VerificationError carrying actual == 3.
        let failing: [CountMatchingStrategy] = [
            .exactly(2), .lessThan(3), .lessThanOrExactly(2), .moreThan(3), .moreThanOrExactly(4),
        ]
        for strategy in failing {
            do {
                try wireMock.verify(strategy, builder)
                XCTFail("expected \(strategy) to fail for actual count 3")
            } catch let error as VerificationError {
                XCTAssertEqual(error.actual, 3)
                XCTAssertFalse(error.expected.isEmpty)
            }
        }
    }

    func testVerifyDefaultRequiresAtLeastOne() throws {
        try wireMock.stubFor(get(urlEqualTo("/never")).willReturn(ok()))
        do {
            try wireMock.verify(getRequestedFor(urlEqualTo("/never")))
            XCTFail("verify should fail when no request was made")
        } catch let error as VerificationError {
            XCTAssertEqual(error.actual, 0)
        }
    }

    // MARK: Global settings round-trip

    func testGlobalSettingsRoundTripWithDelayDistribution() throws {
        try wireMock.updateGlobalSettings(
            GlobalSettings(delayDistribution: .uniform(lower: 20, upper: 40))
        )
        let settings = try wireMock.getGlobalSettings()
        if case .uniform(let lower, let upper)? = settings.delayDistribution {
            XCTAssertEqual(lower, 20)
            XCTAssertEqual(upper, 40)
        } else {
            XCTFail("delayDistribution did not round-trip as uniform: \(String(describing: settings.delayDistribution))")
        }
        // Reset delay so it doesn't slow later tests.
        try wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 0))
    }

    func testGlobalSettingsExtendedKeysPreserved() throws {
        // proxyPassThrough is always returned and typed — must not be dropped.
        let base = try wireMock.getGlobalSettings()
        XCTAssertNotNil(base.proxyPassThrough, "proxyPassThrough must be captured, not dropped")

        // `extended` must round-trip through the server: it is sent under the
        // nested `extended` key (a top-level key would be silently ignored).
        try wireMock.updateGlobalSettings(GlobalSettings(extended: ["custom": .int(7)]))
        let readBack = try wireMock.getGlobalSettings()
        XCTAssertEqual(readBack.extended?["custom"], .int(7),
                       "extended settings must survive a POST→GET round-trip")
        try wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 0))
    }

    // MARK: - Acceptance coverage: verify(count), verbs, random delay, files, since

    func testVerifyExactCountOverload() throws {
        try wireMock.stubFor(get(urlEqualTo("/vc")).willReturn(ok()))
        try WireMockFixture.hit("vc")
        try WireMockFixture.hit("vc")
        try wireMock.verify(2, getRequestedFor(urlEqualTo("/vc")))
        do {
            try wireMock.verify(3, getRequestedFor(urlEqualTo("/vc")))
            XCTFail("verify(3) should have thrown for a count of 2")
        } catch is VerificationError {
            // expected
        }
    }

    func testNonGetVerbsMatchLive() throws {
        try wireMock.stubFor(put(urlEqualTo("/pv")).willReturn(ok("put-ok")))
        try wireMock.stubFor(delete(urlEqualTo("/dv")).willReturn(ok("del-ok")))
        let putBody = String(data: try WireMockFixture.hit("pv", method: "PUT").0, encoding: .utf8)
        let delBody = String(data: try WireMockFixture.hit("dv", method: "DELETE").0, encoding: .utf8)
        XCTAssertEqual(putBody, "put-ok")
        XCTAssertEqual(delBody, "del-ok")
        // Negative: a GET to a PUT-only stub must not match.
        let getStatus = try WireMockFixture.hit("pv").1.statusCode
        XCTAssertEqual(getStatus, 404, "GET must not match a PUT stub")
    }

    func testSetGlobalRandomDelayRoundTrip() throws {
        try wireMock.setGlobalRandomDelay(.uniform(lower: 10, upper: 20))
        let settings = try wireMock.getGlobalSettings()
        XCTAssertEqual(settings.delayDistribution, .uniform(lower: 10, upper: 20))
        // Reset doesn't clear the distribution; neutralize it so later tests aren't slowed.
        try wireMock.setGlobalRandomDelay(.uniform(lower: 0, upper: 0))
    }

    func testListFilesLive() throws {
        try wireMock.putFile(named: "acc.txt", text: "hi")
        let files = try wireMock.listFiles()
        XCTAssertTrue(files.contains("acc.txt"), "listFiles should include the uploaded file; got \(files)")
        try wireMock.deleteFile(named: "acc.txt")
    }

    func testGetServeEventsSinceWithTimezoneOffset() throws {
        try wireMock.stubFor(get(urlEqualTo("/se")).willReturn(ok()))
        try WireMockFixture.hit("se")

        // Exercises the `+`-offset value through AdminClient's query encoding and
        // asserts the `since` filter semantics both ways. NOTE: the `+`→`%2B`
        // escaping itself is *defensive* (spec-correctness) — WireMock 3.13.2's
        // `since` parser accepts a literal `+` too, so that escaping is not
        // behaviourally observable against this server (a known mutation exception).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 5 * 3600)
        let pastWithOffset = iso.string(from: Date().addingTimeInterval(-3600))
        XCTAssertTrue(pastWithOffset.contains("+05:00"),
                      "precondition: the timestamp must carry a +offset; got \(pastWithOffset)")

        let events = try wireMock.getServeEvents(since: pastWithOffset)
        XCTAssertGreaterThanOrEqual(events.count, 1, "a past `since` must include the recorded event")

        // A genuinely future `since` must exclude it — this is what actually
        // discriminates a working `since` from an ignored one.
        let future = try wireMock.getServeEvents(since: "2999-01-01T00:00:00+00:00")
        XCTAssertEqual(future.count, 0, "a future `since` must exclude the past event")
    }

    func testGetServeEventsUnmatchedOnly() throws {
        try wireMock.stubFor(get(urlEqualTo("/matched")).willReturn(ok()))
        _ = try WireMockFixture.hit("matched")        // matched
        _ = try WireMockFixture.hit("no-such-path")   // unmatched → 404

        let unmatched = try wireMock.getServeEvents(unmatchedOnly: true)
        let all = try wireMock.getServeEvents()
        XCTAssertGreaterThan(all.count, unmatched.count, "unmatched-only must be a strict subset when a matched event exists")
        XCTAssertTrue(unmatched.allSatisfy { $0.wasMatched == false }, "every returned event must be unmatched")
        XCTAssertTrue(unmatched.contains { $0.request.url == "/no-such-path" }, "the unmatched request must be present")
        XCTAssertFalse(unmatched.contains { $0.request.url == "/matched" }, "the matched request must be excluded")
    }

    func testRegisterJsonDirectly() throws {
        // The register(json:) escape hatch registers a working stub directly.
        try wireMock.register(json: [
            "request": ["method": "GET", "url": "/direct-json"],
            "response": ["status": 201, "body": "hi"],
        ])
        let (data, http) = try WireMockFixture.hit("direct-json")
        XCTAssertEqual(http.statusCode, 201)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi")
    }
}
