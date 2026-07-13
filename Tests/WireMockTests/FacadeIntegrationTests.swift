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
        wireMock = try await TestServer.clientOrSkip()
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

        let (data, _) = try await TestServer.hit("e")
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
        _ = try await TestServer.hit("se")

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
        _ = try await TestServer.hit("expectd") // near miss
        let unmatched = try await wireMock.getUnmatchedRequests()
        let request = try XCTUnwrap(unmatched.first)

        let misses = try await wireMock.findNearMisses(for: request)
        XCTAssertFalse(misses.isEmpty)
        XCTAssertNotNil(misses.first?.matchResult?.distance)
    }

    func testFindNearMissesForPattern() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/exact")).willReturn(ok()))
        _ = try await TestServer.hit("exact")

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
        let (data, _) = try await TestServer.hit("sc")
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
            let (data, _) = try await TestServer.hit(path)
            XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        }
    }

    // MARK: Count strategies (exhaustive, including failures)

    func testCountStrategiesExhaustive() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/c")).willReturn(ok()))
        for _ in 0..<3 { _ = try await TestServer.hit("c") }
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
        // The live server always returns proxyPassThrough and may include other
        // keys; getGlobalSettings must not drop them. proxyPassThrough is typed.
        let settings = try await wireMock.getGlobalSettings()
        XCTAssertNotNil(settings.proxyPassThrough,
                        "proxyPassThrough must be captured, not dropped")
    }
}
