import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end coverage of verification, scenarios, settings, recording, files,
/// metadata, and the raw escape hatch — all against a real WireMock server.
/// Auto-skips when no server is reachable.
final class AdminIntegrationTests: XCTestCase {
    private var wireMock: WireMock!

    override func setUp() async throws {
        wireMock = try await WireMockFixture.clientOrSkip()
    }

    override func tearDown() async throws {
        if wireMock != nil {
            // `POST /__admin/reset` does NOT clear a global fixed delay, so a test
            // that sets one (and fails before its own cleanup) would leak it into
            // every subsequent test. Reset it explicitly.
            try? await wireMock.setGlobalFixedDelay(0)
            try? await wireMock.resetAll()
        }
    }

    // MARK: Verification & journal

    func testVerifyCountStrategies() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok()))
        for _ in 0..<3 { try await WireMockFixture.hit("ping") }

        try await wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
        try await wireMock.verify(.exactly(3), getRequestedFor(urlEqualTo("/ping")))
        try await wireMock.verify(.moreThanOrExactly(2), getRequestedFor(urlEqualTo("/ping")))
        try await wireMock.verify(.lessThan(4), getRequestedFor(urlEqualTo("/ping")))

        do {
            try await wireMock.verify(.exactly(1), getRequestedFor(urlEqualTo("/ping")))
            XCTFail("Expected verification to fail")
        } catch let error as VerificationError {
            XCTAssertEqual(error.actual, 3)
        }
    }

    func testFindAllAndServeEvents() async throws {
        try await wireMock.stubFor(post(urlEqualTo("/collect")).willReturn(ok()))
        try await WireMockFixture.hit("collect", method: "POST", body: Data("hello".utf8))

        let matched = try await wireMock.findAll(postRequestedFor(urlEqualTo("/collect")))
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.body, "hello")

        let events = try await wireMock.getAllServeEvents()
        XCTAssertTrue(events.contains { $0.request.url == "/collect" })
    }

    func testUnmatchedAndNearMisses() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        _ = try await WireMockFixture.hit("expectd") // typo -> unmatched

        let unmatched = try await wireMock.getUnmatchedRequests()
        XCTAssertTrue(unmatched.contains { $0.url == "/expectd" })

        let nearMisses = try await wireMock.findNearMissesForAllUnmatched()
        XCTAssertFalse(nearMisses.isEmpty)
    }

    func testResetRequests() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/x")).willReturn(ok()))
        try await WireMockFixture.hit("x")
        let before = try await wireMock.count(getRequestedFor(urlEqualTo("/x")))
        XCTAssertEqual(before, 1)
        try await wireMock.resetRequests()
        let after = try await wireMock.count(getRequestedFor(urlEqualTo("/x")))
        XCTAssertEqual(after, 0)
    }

    // MARK: Matchers (contract-verifying)

    func testQueryParamRegexMatcherMatchesOnServer() async throws {
        try await wireMock.stubFor(
            get(urlPathEqualTo("/num")).withQueryParam("n", matching("[0-9]+")).willReturn(ok("digits"))
        )
        let matched = try await WireMockFixture.hit("num?n=20")
        XCTAssertEqual(matched.1.statusCode, 200)
        let unmatched = try await WireMockFixture.hit("num?n=abc")
        XCTAssertEqual(unmatched.1.statusCode, 404)
    }

    func testJsonPathBodyMatcherMatchesOnServer() async throws {
        try await wireMock.stubFor(
            post(urlEqualTo("/j")).withRequestBody(matchingJsonPath("$.name")).willReturn(ok())
        )
        let hit = try await WireMockFixture.hit("j", method: "POST", headers: ["Content-Type": "application/json"], body: Data(#"{"name":"bob"}"#.utf8))
        XCTAssertEqual(hit.1.statusCode, 200)
        let miss = try await WireMockFixture.hit("j", method: "POST", headers: ["Content-Type": "application/json"], body: Data(#"{"age":1}"#.utf8))
        XCTAssertEqual(miss.1.statusCode, 404)
    }

    // MARK: Scenarios

    func testStatefulScenario() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/state")).inScenario("s").whenScenarioStateIs("Started")
                .willSetStateTo("second").willReturn(ok("first"))
        )
        try await wireMock.stubFor(
            get(urlEqualTo("/state")).inScenario("s").whenScenarioStateIs("second")
                .willReturn(ok("second"))
        )

        var (data, response) = try await WireMockFixture.hit("state")
        XCTAssertEqual(String(data: data, encoding: .utf8), "first")
        XCTAssertEqual(response.statusCode, 200)

        (data, _) = try await WireMockFixture.hit("state")
        XCTAssertEqual(String(data: data, encoding: .utf8), "second")

        let scenarios = try await wireMock.getAllScenarios()
        XCTAssertTrue(scenarios.contains { $0.name == "s" })

        try await wireMock.resetAllScenarios()
        (data, _) = try await WireMockFixture.hit("state")
        XCTAssertEqual(String(data: data, encoding: .utf8), "first", "reset should return to Started")
    }

    // MARK: Settings

    func testGlobalFixedDelay() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/slow")).willReturn(ok()))
        try await wireMock.setGlobalFixedDelay(400)
        let start = Date()
        _ = try await WireMockFixture.hit("slow")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3)
        try await wireMock.setGlobalFixedDelay(0)
    }

    // MARK: Recording lifecycle

    func testRecordingLifecycle() async throws {
        // Initial status isn't asserted: recording state is not cleared by
        // resetAll, so it depends on test ordering. We assert the transitions.
        try await wireMock.startRecording(targetBaseUrl: "http://localhost:9999")
        let recording = try await wireMock.getRecordingStatus()
        XCTAssertEqual(recording, "Recording")
        _ = try await wireMock.stopRecording()
        let stopped = try await wireMock.getRecordingStatus()
        XCTAssertEqual(stopped, "Stopped")
    }

    func testSnapshotEndpoint() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/rec")).willReturn(ok("recorded")))
        try await WireMockFixture.hit("rec")
        // Requests already served by a stub are not re-snapshotted; the call
        // must still succeed and decode to a (here empty) mapping list.
        let snapshot = try await wireMock.takeSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    // MARK: Files

    func testFileLifecycle() async throws {
        try await wireMock.putFile(named: "greeting.json", text: #"{"hi":true}"#, contentType: "application/json")

        try await wireMock.stubFor(
            get(urlEqualTo("/file")).willReturn(aResponse().withStatus(200).withBodyFile("greeting.json"))
        )
        let (data, response) = try await WireMockFixture.hit("file")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), ["hi": true])

        let fetched = try await wireMock.getFile(named: "greeting.json")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: fetched), ["hi": true])

        try await wireMock.deleteFile(named: "greeting.json")
    }

    // MARK: Metadata

    func testMetadataFindAndRemove() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/meta")).withMetadata(["team": "payments"]).willReturn(ok())
        )
        let matcher = StringValuePattern.matchingJsonPath("$.team", equalTo("payments"))
        let found = try await wireMock.findStubsByMetadata(matcher)
        XCTAssertEqual(found.count, 1)

        try await wireMock.removeStubsByMetadata(matcher)
        let remaining = try await wireMock.findStubsByMetadata(matcher).count
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Import & raw escape hatch

    func testImportMappings() async throws {
        let stub = get(urlEqualTo("/imported")).willReturn(ok("yes")).build()
        try await wireMock.importMappings([stub])
        let (data, _) = try await WireMockFixture.hit("imported")
        XCTAssertEqual(String(data: data, encoding: .utf8), "yes")
    }

    func testImportWithDeleteAllNotInImport() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/old")).willReturn(ok()))
        // Importing with deleteAllNotInImport must drop the pre-existing /old stub.
        try await wireMock.importMappings(
            [get(urlEqualTo("/new")).willReturn(ok("new")).build()],
            duplicatePolicy: .overwrite,
            deleteAllNotInImport: true
        )
        let newStatus = try await WireMockFixture.hit("new").1.statusCode
        let oldStatus = try await WireMockFixture.hit("old").1.statusCode
        XCTAssertEqual(newStatus, 200)
        XCTAssertEqual(oldStatus, 404, "deleteAllNotInImport should remove /old")
    }

    func testRemoveStubByPattern() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/byebye")).willReturn(ok()))
        let before = try await WireMockFixture.hit("byebye").1.statusCode
        XCTAssertEqual(before, 200)
        // Remove it by re-describing the stub, without knowing its id.
        try await wireMock.removeStub(get(urlEqualTo("/byebye")).willReturn(ok()))
        let after = try await WireMockFixture.hit("byebye").1.statusCode
        XCTAssertEqual(after, 404)
    }

    func testRawRegister() async throws {
        try await wireMock.register(raw: #"""
        { "request": { "method": "GET", "url": "/raw" },
          "response": { "status": 200, "body": "raw-ok" } }
        """#)
        let (data, _) = try await WireMockFixture.hit("raw")
        XCTAssertEqual(String(data: data, encoding: .utf8), "raw-ok")
    }
}
