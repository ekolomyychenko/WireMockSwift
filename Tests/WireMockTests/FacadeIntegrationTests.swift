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

    override func setUp() async throws {
        wireMock = try await WireMockFixture.clientOrSkip()
    }

    override func tearDown() async throws {
        if wireMock != nil {
            try? await wireMock.setGlobalFixedDelay(0)
            try? await wireMock.resetAll()
        }
    }

    // MARK: Mapping CRUD

    func testGetStubMapping() async throws {
        let created = try await wireMock.stubFor(get(urlEqualTo("/g")).willReturn(ok("hi")))
        let id = try XCTUnwrap(created.id)
        let fetched = try await wireMock.getStubMapping(id: id)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.request.url, "/g")
        XCTAssertEqual(fetched.response.body, "hi")
    }

    func testEditStubMapping() async throws {
        let created = try await wireMock.stubFor(get(urlEqualTo("/e")).willReturn(ok("before")))
        let id = try XCTUnwrap(created.id)

        var updated = created
        updated.response = ok("after").definition
        let result = try await wireMock.editStubMapping(id: id, updated)
        XCTAssertEqual(result.id, id)

        let (data, _) = try await WireMockFixture.hit("e")
        XCTAssertEqual(String(data: data, encoding: .utf8), "after", "edit should replace the served body")
    }

    func testRemoveAllMappings() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/a")).willReturn(ok()))
        try await wireMock.stubFor(get(urlEqualTo("/b")).willReturn(ok()))
        let before = try await wireMock.listAllStubMappings()
        XCTAssertFalse(before.isEmpty)

        try await wireMock.removeAllMappings()
        let after = try await wireMock.listAllStubMappings()
        XCTAssertTrue(after.isEmpty)
    }

    func testResetToDefaultMappings() async throws {
        // With no persisted baseline on disk, resetToDefaultMappings clears the
        // in-memory stubs (reloads the empty default set) without throwing.
        try await wireMock.stubFor(get(urlEqualTo("/transient")).willReturn(ok()))
        try await wireMock.resetToDefaultMappings()
        let all = try await wireMock.listAllStubMappings()
        XCTAssertFalse(all.contains { $0.request.url == "/transient" },
                       "transient stub should be gone after resetToDefaultMappings")
    }

    // MARK: Serve events

    func testGetAndRemoveServeEvent() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/se")).willReturn(ok()))
        _ = try await WireMockFixture.hit("se")

        let events = try await wireMock.getAllServeEvents()
        let event = try XCTUnwrap(events.first { $0.request.url == "/se" })
        let id = try XCTUnwrap(event.id)

        let fetched = try await wireMock.getServeEvent(id: id)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.request.url, "/se")

        try await wireMock.removeServeEvent(id: id)
        let remaining = try await wireMock.getAllServeEvents()
        XCTAssertFalse(remaining.contains { $0.id == id }, "serve event should be removed")
    }

    // MARK: Near misses

    func testFindNearMissesForRequest() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        _ = try await WireMockFixture.hit("expectd") // near miss
        let unmatched = try await wireMock.getUnmatchedRequests()
        let request = try XCTUnwrap(unmatched.first)

        let misses = try await wireMock.findNearMisses(for: request)
        XCTAssertFalse(misses.isEmpty)
        XCTAssertNotNil(misses.first?.matchResult?.distance)
    }

    func testFindNearMissesForPattern() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/exact")).willReturn(ok()))
        _ = try await WireMockFixture.hit("exact")

        // A pattern for a slightly different URL should report the served
        // request as a near miss.
        let misses = try await wireMock.findNearMisses(for: getRequestedFor(urlEqualTo("/exacts")))
        XCTAssertFalse(misses.isEmpty)
        XCTAssertNotNil(misses.first?.request)
    }

    // MARK: Scenarios

    func testSetScenarioStateExplicitly() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/sc")).inScenario("flow").whenScenarioStateIs("Started").willReturn(ok("first"))
        )
        try await wireMock.stubFor(
            get(urlEqualTo("/sc")).inScenario("flow").whenScenarioStateIs("jumped").willReturn(ok("jumped"))
        )
        // Jump straight to a non-initial state.
        try await wireMock.setScenarioState(name: "flow", state: "jumped")
        let (data, _) = try await WireMockFixture.hit("sc")
        XCTAssertEqual(String(data: data, encoding: .utf8), "jumped")

        let scenarios = try await wireMock.getAllScenarios()
        let scenario = try XCTUnwrap(scenarios.first { $0.name == "flow" })
        XCTAssertEqual(scenario.state, "jumped")
        // possibleStates should include both declared states.
        let possible = Set(scenario.possibleStates ?? [])
        XCTAssertTrue(possible.contains("Started"))
        XCTAssertTrue(possible.contains("jumped"))
    }

    // MARK: Bulk import (multiple)

    func testImportMultipleMappings() async throws {
        let stubs = [
            get(urlEqualTo("/one")).willReturn(ok("1")).build(),
            get(urlEqualTo("/two")).willReturn(ok("2")).build(),
            get(urlEqualTo("/three")).willReturn(ok("3")).build(),
        ]
        try await wireMock.importMappings(stubs)
        for (path, expected) in [("one", "1"), ("two", "2"), ("three", "3")] {
            let (data, _) = try await WireMockFixture.hit(path)
            XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        }
    }

    // MARK: Count strategies (exhaustive, including failures)

    func testCountStrategiesExhaustive() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/c")).willReturn(ok()))
        for _ in 0..<3 { _ = try await WireMockFixture.hit("c") }
        let builder = getRequestedFor(urlEqualTo("/c"))

        // Passing cases.
        try await wireMock.verify(.exactly(3), builder)
        try await wireMock.verify(.lessThan(4), builder)
        try await wireMock.verify(.lessThanOrExactly(3), builder)
        try await wireMock.verify(.moreThan(2), builder)
        try await wireMock.verify(.moreThanOrExactly(3), builder)

        // Failing cases: each must throw VerificationError carrying actual == 3.
        let failing: [CountMatchingStrategy] = [
            .exactly(2), .lessThan(3), .lessThanOrExactly(2), .moreThan(3), .moreThanOrExactly(4),
        ]
        for strategy in failing {
            do {
                try await wireMock.verify(strategy, builder)
                XCTFail("expected \(strategy) to fail for actual count 3")
            } catch let error as VerificationError {
                XCTAssertEqual(error.actual, 3)
                XCTAssertFalse(error.expected.isEmpty)
            }
        }
    }

    func testVerifyDefaultRequiresAtLeastOne() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/never")).willReturn(ok()))
        do {
            try await wireMock.verify(getRequestedFor(urlEqualTo("/never")))
            XCTFail("verify should fail when no request was made")
        } catch let error as VerificationError {
            XCTAssertEqual(error.actual, 0)
        }
    }

    // MARK: Global settings round-trip

    func testGlobalSettingsRoundTripWithDelayDistribution() async throws {
        try await wireMock.updateGlobalSettings(
            GlobalSettings(delayDistribution: .uniform(lower: 20, upper: 40))
        )
        let settings = try await wireMock.getGlobalSettings()
        if case .uniform(let lower, let upper)? = settings.delayDistribution {
            XCTAssertEqual(lower, 20)
            XCTAssertEqual(upper, 40)
        } else {
            XCTFail("delayDistribution did not round-trip as uniform: \(String(describing: settings.delayDistribution))")
        }
        // Reset delay so it doesn't slow later tests.
        try await wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 0))
    }

    func testGlobalSettingsExtendedKeysPreserved() async throws {
        // proxyPassThrough is always returned and typed — must not be dropped.
        let base = try await wireMock.getGlobalSettings()
        XCTAssertNotNil(base.proxyPassThrough, "proxyPassThrough must be captured, not dropped")

        // `extended` must round-trip through the server: it is sent under the
        // nested `extended` key (a top-level key would be silently ignored).
        try await wireMock.updateGlobalSettings(GlobalSettings(extended: ["custom": .int(7)]))
        let readBack = try await wireMock.getGlobalSettings()
        XCTAssertEqual(readBack.extended?["custom"], .int(7),
                       "extended settings must survive a POST→GET round-trip")
        try await wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 0))
    }

    // MARK: - Acceptance coverage: verify(count), verbs, random delay, files, since

    func testVerifyExactCountOverload() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/vc")).willReturn(ok()))
        try await WireMockFixture.hit("vc")
        try await WireMockFixture.hit("vc")
        try await wireMock.verify(2, getRequestedFor(urlEqualTo("/vc")))
        do {
            try await wireMock.verify(3, getRequestedFor(urlEqualTo("/vc")))
            XCTFail("verify(3) should have thrown for a count of 2")
        } catch is VerificationError {
            // expected
        }
    }

    func testNonGetVerbsMatchLive() async throws {
        try await wireMock.stubFor(put(urlEqualTo("/pv")).willReturn(ok("put-ok")))
        try await wireMock.stubFor(delete(urlEqualTo("/dv")).willReturn(ok("del-ok")))
        let putBody = String(data: try await WireMockFixture.hit("pv", method: "PUT").0, encoding: .utf8)
        let delBody = String(data: try await WireMockFixture.hit("dv", method: "DELETE").0, encoding: .utf8)
        XCTAssertEqual(putBody, "put-ok")
        XCTAssertEqual(delBody, "del-ok")
        // Negative: a GET to a PUT-only stub must not match.
        let getStatus = try await WireMockFixture.hit("pv").1.statusCode
        XCTAssertEqual(getStatus, 404, "GET must not match a PUT stub")
    }

    func testSetGlobalRandomDelayRoundTrip() async throws {
        try await wireMock.setGlobalRandomDelay(.uniform(lower: 10, upper: 20))
        let settings = try await wireMock.getGlobalSettings()
        XCTAssertEqual(settings.delayDistribution, .uniform(lower: 10, upper: 20))
        // Reset doesn't clear the distribution; neutralize it so later tests aren't slowed.
        try await wireMock.setGlobalRandomDelay(.uniform(lower: 0, upper: 0))
    }

    func testListFilesLive() async throws {
        try await wireMock.putFile(named: "acc.txt", text: "hi")
        let files = try await wireMock.listFiles()
        XCTAssertTrue(files.contains("acc.txt"), "listFiles should include the uploaded file; got \(files)")
        try await wireMock.deleteFile(named: "acc.txt")
    }

    func testGetServeEventsSinceWithTimezoneOffset() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/se")).willReturn(ok()))
        try await WireMockFixture.hit("se")
        // `since` carries a `+hh:mm` offset — exercises the query percent-encoding path.
        let past = try await wireMock.getServeEvents(since: "2020-01-01T00:00:00+00:00")
        XCTAssertGreaterThanOrEqual(past.count, 1, "a past `since` must include the recorded event")
    }
}
