import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pure (hermetic) decode-contract tests driven by fixtures **captured from the
/// real pinned WireMock server** (`Scripts/capture-fixtures.sh` →
/// `Tests/WireMockTests/Fixtures/*.json`). Unlike the hand-transcribed literals in
/// `ModelDecodingTests`, these shapes cannot silently drift from what 3.13.2
/// actually emits: regenerating the fixtures against an unchanged server is a
/// no-op diff, and a real wire-format change shows up in `git diff` and must be
/// reconciled with the decoders here.
///
/// Volatile fields (ids, timestamps, timings) are normalised to placeholders by
/// the capture script, so the assertions below pin structure and stable values.
final class RecordedContractTests: XCTestCase {

    private func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json — run Scripts/capture-fixtures.sh"
        )
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: Serve events (matched + unmatched with subEvents) + LoggedRequest

    func testServeEventsFixtureDecodes() throws {
        let arr = try XCTUnwrap(fixture("serve-events").objectValue?["requests"]?.arrayValue)
        let events = try arr.map { try decode(ServeEvent.self, $0) }
        XCTAssertEqual(events.count, 2)

        let matched = try XCTUnwrap(events.first { $0.wasMatched == true })
        XCTAssertEqual(matched.request.url, "/form")
        XCTAssertEqual(matched.request.method, "POST")
        XCTAssertEqual(matched.response?.status, 201)
        // The matched request is a full LoggedRequest carrying the captured form body.
        XCTAssertEqual(matched.request.headers?["Content-Type"], .single("application/x-www-form-urlencoded"))
        XCTAssertEqual(try XCTUnwrap(matched.request.body).contains("name=bob"), true)

        let unmatched = try XCTUnwrap(events.first { $0.wasMatched == false })
        XCTAssertEqual(unmatched.request.url, "/no-such-stub-unmatched")
        let sub = try XCTUnwrap(unmatched.subEvents?.first)
        XCTAssertEqual(sub.type, "REQUEST_NOT_MATCHED")
        XCTAssertEqual(try XCTUnwrap(sub.data?.objectValue?["report"]?.stringValue).contains("Request was not matched"), true)
    }

    // MARK: Near miss

    func testNearMissFixtureDecodes() throws {
        let arr = try XCTUnwrap(fixture("near-misses").objectValue?["nearMisses"]?.arrayValue)
        let miss = try decode(NearMiss.self, try XCTUnwrap(arr.first))
        XCTAssertEqual(miss.request?.url, "/no-such-stub-unmatched")
        XCTAssertEqual(miss.requestPattern?.url, "/expected")
        let distance = try XCTUnwrap(miss.matchResult?.distance)
        XCTAssertGreaterThan(distance, 0, "a near miss must carry a positive distance")
    }

    // MARK: Scenario

    func testScenariosFixtureDecodes() throws {
        let arr = try XCTUnwrap(fixture("scenarios").objectValue?["scenarios"]?.arrayValue)
        let scenario = try decode(Scenario.self, try XCTUnwrap(arr.first))
        XCTAssertEqual(scenario.name, "flow")
        XCTAssertEqual(scenario.state, "Started")
        XCTAssertEqual(Set(try XCTUnwrap(scenario.possibleStates)), ["Started", "next"])
    }

    // MARK: Global settings

    func testSettingsFixtureDecodes() throws {
        let settings = try decode(GlobalSettings.self, try XCTUnwrap(fixture("settings").objectValue?["settings"]))
        XCTAssertEqual(settings.fixedDelay, 5)
        XCTAssertEqual(settings.proxyPassThrough, true)
        XCTAssertEqual(settings.extended?["custom"], 1)
    }

    // MARK: Snapshot result

    func testSnapshotFixtureDecodes() throws {
        let result = try decode(SnapshotResult.self, fixture("snapshot"))
        let mappings = try XCTUnwrap(result.mappings)
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.request.url, "/snapme")
    }

    // MARK: Recording status

    func testRecordingStatusFixtureDecodes() throws {
        XCTAssertEqual(try fixture("recording-status") /* {"status":"Stopped"} */
            .objectValue?["status"]?.stringValue, "Stopped")
    }

    // MARK: Mappings list

    func testMappingsListFixtureDecodes() throws {
        let arr = try XCTUnwrap(fixture("mappings-list").objectValue?["mappings"]?.arrayValue)
        let mappings = try arr.map { try decode(StubMapping.self, $0) }
        XCTAssertTrue(mappings.contains { $0.request.url == "/form" || $0.request.urlPath == "/form" },
                      "the captured mappings must include the /form stub")
    }
}
