import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end coverage of verification, scenarios, settings, recording, files,
/// metadata, and the raw escape hatch — all against a real WireMock server.
/// Auto-skips when no server is reachable.
final class AdminIntegrationTests: WireMockIntegrationCase {

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

        // Pin the near-miss content: it must describe the /expectd request and
        // point at the /expected stub — non-emptiness alone would pass even if
        // the linkage were dropped or the wrong request were returned.
        let nearMisses = try wireMock.findNearMissesForAllUnmatched()
        XCTAssertEqual(nearMisses.count, 1)
        XCTAssertEqual(nearMisses.first?.request?.url, "/expectd")
        XCTAssertEqual(nearMisses.first?.stubMapping?.request.url, "/expected")
        XCTAssertNotNil(nearMisses.first?.matchResult?.distance)
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
        WireMockFixture.assertMatch(matched)
        let unmatched = try WireMockFixture.hit("num?n=abc")
        WireMockFixture.assertMiss(unmatched)
    }

    func testJsonPathBodyMatcherMatchesOnServer() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/j")).withRequestBody(matchingJsonPath("$.name")).willReturn(ok())
        )
        let hit = try WireMockFixture.hit("j", method: "POST", headers: ["Content-Type": "application/json"], body: Data(#"{"name":"bob"}"#.utf8))
        WireMockFixture.assertMatch(hit)
        let miss = try WireMockFixture.hit("j", method: "POST", headers: ["Content-Type": "application/json"], body: Data(#"{"age":1}"#.utf8))
        WireMockFixture.assertMiss(miss)
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
        try WireMockFixture.assertTakesAtLeast(0.3) { _ = try WireMockFixture.hit("slow") }
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

    func testSnapshotGeneratesMappingFromProxiedRequest() throws {
        // `takeSnapshot` turns *proxied* journal entries into stub mappings (a
        // request already served by a local stub is NOT re-snapshotted). Proxy to
        // a dead sub-path so the forwarded request is journalled without a real
        // backend, then prove the snapshot returns a concrete generated mapping.
        // (Asserting only `isEmpty` here would pass even if takeSnapshot always
        // returned [], which is why the previous version proved nothing.)
        let deadTarget = WireMockFixture.baseURL.absoluteString + "/nowhere"
        try wireMock.stubFor(get(urlEqualTo("/snapme")).willReturn(aResponse().proxiedFrom(deadTarget)))
        _ = try WireMockFixture.hit("snapme")

        // persist: false — a snapshot defaults to PERSISTENT stubs, which survive
        // resetAll() and would leak into every later suite sharing this server.
        let snapshot = try wireMock.takeSnapshot(RecordSpec(persist: false))
        XCTAssertFalse(snapshot.isEmpty, "a proxied request must yield at least one generated mapping")
        XCTAssertTrue(snapshot.contains { $0.request.url == "/snapme" },
                      "the generated mapping must describe the proxied request; got \(snapshot.map { $0.request.url })")
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
        // The delete must actually remove the file — fetching it now 404s.
        XCTAssertThrowsError(try wireMock.getFile(named: "greeting.json"), "deleted file should be gone") { error in
            guard case WireMockError.unexpectedStatus(let code, _) = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
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

    func testImportMappingsIgnoreVsOverwriteOnIdCollision() throws {
        // The whole point of duplicatePolicy is what happens when an imported id
        // already exists. IGNORE keeps the incumbent; OVERWRITE replaces it. The
        // suite previously only exercised OVERWRITE, so IGNORE could have been
        // silently broken (or the two swapped) and stayed green.
        let id = UUID()
        let original = get(urlEqualTo("/dup")).willReturn(ok("A")).withId(id).build()
        let replacement = get(urlEqualTo("/dup")).willReturn(ok("B")).withId(id).build()

        try wireMock.importMappings([original])
        XCTAssertEqual(String(decoding: try WireMockFixture.hit("dup").0, as: UTF8.self), "A",
                       "precondition: the original mapping serves A")

        try wireMock.importMappings([replacement], duplicatePolicy: .ignore)
        XCTAssertEqual(String(decoding: try WireMockFixture.hit("dup").0, as: UTF8.self), "A",
                       "IGNORE must keep the incumbent mapping for a colliding id")

        try wireMock.importMappings([replacement], duplicatePolicy: .overwrite)
        XCTAssertEqual(String(decoding: try WireMockFixture.hit("dup").0, as: UTF8.self), "B",
                       "OVERWRITE must replace the mapping for the colliding id")
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
