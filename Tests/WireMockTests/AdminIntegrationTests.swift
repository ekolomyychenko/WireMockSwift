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

    override func setUpWithError() throws {
        wireMock = try WireMockFixture.clientOrSkip()
    }

    override func tearDownWithError() throws {
        if wireMock != nil {
            // `POST /__admin/reset` does NOT clear a global fixed delay, so a test
            // that sets one (and fails before its own cleanup) would leak it into
            // every subsequent test. Reset it explicitly.
            try? wireMock.setGlobalFixedDelay(0)
            try? wireMock.resetAll()
        }
    }

    // MARK: Verification & journal

    func testVerifyCountStrategies() throws {
        try wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok()))
        for _ in 0..<3 { try WireMockFixture.hit("ping") }

        try wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
        try wireMock.verify(.exactly(3), getRequestedFor(urlEqualTo("/ping")))
        try wireMock.verify(.moreThanOrExactly(2), getRequestedFor(urlEqualTo("/ping")))
        try wireMock.verify(.lessThan(4), getRequestedFor(urlEqualTo("/ping")))

        do {
            try wireMock.verify(.exactly(1), getRequestedFor(urlEqualTo("/ping")))
            XCTFail("Expected verification to fail")
        } catch let error as VerificationError {
            XCTAssertEqual(error.actual, 3)
        }
    }

    func testFindAllAndServeEvents() throws {
        try wireMock.stubFor(post(urlEqualTo("/collect")).willReturn(ok()))
        try WireMockFixture.hit("collect", method: "POST", body: Data("hello".utf8))

        let matched = try wireMock.findAll(postRequestedFor(urlEqualTo("/collect")))
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.body, "hello")

        let events = try wireMock.getAllServeEvents()
        XCTAssertTrue(events.contains { $0.request.url == "/collect" })
    }

    func testUnmatchedAndNearMisses() throws {
        try wireMock.stubFor(get(urlEqualTo("/expected")).willReturn(ok()))
        _ = try WireMockFixture.hit("expectd") // typo -> unmatched

        let unmatched = try wireMock.getUnmatchedRequests()
        XCTAssertTrue(unmatched.contains { $0.url == "/expectd" })

        let nearMisses = try wireMock.findNearMissesForAllUnmatched()
        XCTAssertFalse(nearMisses.isEmpty)
    }

    func testResetRequests() throws {
        try wireMock.stubFor(get(urlEqualTo("/x")).willReturn(ok()))
        try WireMockFixture.hit("x")
        let before = try wireMock.count(getRequestedFor(urlEqualTo("/x")))
        XCTAssertEqual(before, 1)
        try wireMock.resetRequests()
        let after = try wireMock.count(getRequestedFor(urlEqualTo("/x")))
        XCTAssertEqual(after, 0)
    }

    // MARK: Matchers (contract-verifying)

    func testQueryParamRegexMatcherMatchesOnServer() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/num")).withQueryParam("n", matching("[0-9]+")).willReturn(ok("digits"))
        )
        let matched = try WireMockFixture.hit("num?n=20")
        XCTAssertEqual(matched.1.statusCode, 200)
        let unmatched = try WireMockFixture.hit("num?n=abc")
        XCTAssertEqual(unmatched.1.statusCode, 404)
    }

    func testJsonPathBodyMatcherMatchesOnServer() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/j")).withRequestBody(matchingJsonPath("$.name")).willReturn(ok())
        )
        let hit = try WireMockFixture.hit("j", method: "POST", headers: ["Content-Type": "application/json"], body: Data(#"{"name":"bob"}"#.utf8))
        XCTAssertEqual(hit.1.statusCode, 200)
        let miss = try WireMockFixture.hit("j", method: "POST", headers: ["Content-Type": "application/json"], body: Data(#"{"age":1}"#.utf8))
        XCTAssertEqual(miss.1.statusCode, 404)
    }

    // MARK: Scenarios

    func testStatefulScenario() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/state")).inScenario("s").whenScenarioStateIs("Started")
                .willSetStateTo("second").willReturn(ok("first"))
        )
        try wireMock.stubFor(
            get(urlEqualTo("/state")).inScenario("s").whenScenarioStateIs("second")
                .willReturn(ok("second"))
        )

        var (data, response) = try WireMockFixture.hit("state")
        XCTAssertEqual(String(data: data, encoding: .utf8), "first")
        XCTAssertEqual(response.statusCode, 200)

        (data, _) = try WireMockFixture.hit("state")
        XCTAssertEqual(String(data: data, encoding: .utf8), "second")

        let scenarios = try wireMock.getAllScenarios()
        XCTAssertTrue(scenarios.contains { $0.name == "s" })

        try wireMock.resetAllScenarios()
        (data, _) = try WireMockFixture.hit("state")
        XCTAssertEqual(String(data: data, encoding: .utf8), "first", "reset should return to Started")
    }

    // MARK: Settings

    func testGlobalFixedDelay() throws {
        try wireMock.stubFor(get(urlEqualTo("/slow")).willReturn(ok()))
        try wireMock.setGlobalFixedDelay(400)
        let start = Date()
        _ = try WireMockFixture.hit("slow")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3)
        try wireMock.setGlobalFixedDelay(0)
    }

    // MARK: Recording lifecycle

    func testRecordingLifecycle() throws {
        // Initial status isn't asserted: recording state is not cleared by
        // resetAll, so it depends on test ordering. We assert the transitions.
        try wireMock.startRecording(targetBaseUrl: "http://localhost:9999")
        let recording = try wireMock.getRecordingStatus()
        XCTAssertEqual(recording, "Recording")
        _ = try wireMock.stopRecording()
        let stopped = try wireMock.getRecordingStatus()
        XCTAssertEqual(stopped, "Stopped")
    }

    func testSnapshotEndpoint() throws {
        try wireMock.stubFor(get(urlEqualTo("/rec")).willReturn(ok("recorded")))
        try WireMockFixture.hit("rec")
        // Requests already served by a stub are not re-snapshotted; the call
        // must still succeed and decode to a (here empty) mapping list.
        let snapshot = try wireMock.takeSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    // MARK: Files

    func testFileLifecycle() throws {
        try wireMock.putFile(named: "greeting.json", text: #"{"hi":true}"#, contentType: "application/json")

        try wireMock.stubFor(
            get(urlEqualTo("/file")).willReturn(aResponse().withStatus(200).withBodyFile("greeting.json"))
        )
        let (data, response) = try WireMockFixture.hit("file")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), ["hi": true])

        let fetched = try wireMock.getFile(named: "greeting.json")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: fetched), ["hi": true])

        try wireMock.deleteFile(named: "greeting.json")
    }

    // MARK: Metadata

    func testMetadataFindAndRemove() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/meta")).withMetadata(["team": "payments"]).willReturn(ok())
        )
        let matcher = StringValuePattern.matchingJsonPath("$.team", equalTo("payments"))
        let found = try wireMock.findStubsByMetadata(matcher)
        XCTAssertEqual(found.count, 1)

        try wireMock.removeStubsByMetadata(matcher)
        let remaining = try wireMock.findStubsByMetadata(matcher).count
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Import & raw escape hatch

    func testImportMappings() throws {
        let stub = get(urlEqualTo("/imported")).willReturn(ok("yes")).build()
        try wireMock.importMappings([stub])
        let (data, _) = try WireMockFixture.hit("imported")
        XCTAssertEqual(String(data: data, encoding: .utf8), "yes")
    }

    func testImportWithDeleteAllNotInImport() throws {
        try wireMock.stubFor(get(urlEqualTo("/old")).willReturn(ok()))
        // Importing with deleteAllNotInImport must drop the pre-existing /old stub.
        try wireMock.importMappings(
            [get(urlEqualTo("/new")).willReturn(ok("new")).build()],
            duplicatePolicy: .overwrite,
            deleteAllNotInImport: true
        )
        let newStatus = try WireMockFixture.hit("new").1.statusCode
        let oldStatus = try WireMockFixture.hit("old").1.statusCode
        XCTAssertEqual(newStatus, 200)
        XCTAssertEqual(oldStatus, 404, "deleteAllNotInImport should remove /old")
    }

    func testRemoveStubByPattern() throws {
        try wireMock.stubFor(get(urlEqualTo("/byebye")).willReturn(ok()))
        let before = try WireMockFixture.hit("byebye").1.statusCode
        XCTAssertEqual(before, 200)
        // Remove it by re-describing the stub, without knowing its id.
        try wireMock.removeStub(get(urlEqualTo("/byebye")).willReturn(ok()))
        let after = try WireMockFixture.hit("byebye").1.statusCode
        XCTAssertEqual(after, 404)
    }

    func testRawRegister() throws {
        try wireMock.register(raw: #"""
        { "request": { "method": "GET", "url": "/raw" },
          "response": { "status": 200, "body": "raw-ok" } }
        """#)
        let (data, _) = try WireMockFixture.hit("raw")
        XCTAssertEqual(String(data: data, encoding: .utf8), "raw-ok")
    }
}
