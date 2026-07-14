import Foundation

// MARK: - Verification & request journal

extension WireMock {
    /// Counts journalled requests matching the builder.
    public func count(_ builder: RequestPatternBuilder) async throws -> Int {
        try await countRequests(matching: builder.pattern)
    }

    /// Asserts at least one request matched (`verify(pattern)` in Java).
    public func verify(_ builder: RequestPatternBuilder) async throws {
        try await verify(.moreThanOrExactly(1), builder)
    }

    /// Asserts exactly `count` requests matched (`verify(count, pattern)` in Java).
    public func verify(_ count: Int, _ builder: RequestPatternBuilder) async throws {
        try await verify(.exactly(count), builder)
    }

    /// Asserts the matching-request count satisfies `strategy`.
    public func verify(_ strategy: CountMatchingStrategy, _ builder: RequestPatternBuilder) async throws {
        let actual = try await count(builder)
        guard strategy.isSatisfied(by: actual) else {
            throw VerificationError(expected: strategy.description, actual: actual)
        }
    }

    /// Returns all journalled requests matching the builder.
    public func findAll(_ builder: RequestPatternBuilder) async throws -> [LoggedRequest] {
        let result = try await admin.send("POST", "requests/find", body: builder.pattern, as: FindRequestsResult.self)
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    /// All serve events in the journal (most recent first).
    public func getAllServeEvents() async throws -> [ServeEvent] {
        let result = try await admin.get("requests", as: GetServeEventsResult.self)
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    /// Serve events with server-side filtering (`limit`, `since`, unmatched-only).
    public func getServeEvents(limit: Int? = nil, since: String? = nil, unmatchedOnly: Bool = false) async throws -> [ServeEvent] {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if unmatchedOnly { query.append(URLQueryItem(name: "unmatched", value: "true")) }
        let result = try await admin.get("requests", query: query, as: GetServeEventsResult.self)
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    /// A single serve event by id.
    public func getServeEvent(id: UUID) async throws -> ServeEvent {
        try await admin.get("requests/\(id.uuidString)", as: ServeEvent.self)
    }

    /// Removes a single serve event from the journal.
    public func removeServeEvent(id: UUID) async throws {
        try await admin.send("DELETE", "requests/\(id.uuidString)")
    }

    /// Clears the entire request journal.
    public func resetRequests() async throws {
        try await admin.send("DELETE", "requests")
    }

    /// Removes journalled events matching the pattern; returns the removed events.
    @discardableResult
    public func removeServeEvents(matching builder: RequestPatternBuilder) async throws -> [ServeEvent] {
        try await admin.send("POST", "requests/remove", body: builder.pattern, as: RemovedServeEventsResult.self).serveEvents
    }

    /// Removes journalled events whose originating stub matches the metadata matcher.
    public func removeServeEventsByMetadata(_ matcher: StringValuePattern) async throws {
        try await admin.send("POST", "requests/remove-by-metadata", body: matcher)
    }

    /// Requests received that matched no stub.
    public func getUnmatchedRequests() async throws -> [LoggedRequest] {
        try await admin.get("requests/unmatched", as: FindRequestsResult.self).requests
    }

    // MARK: Near misses

    /// The closest-matching stubs for every request that matched nothing.
    public func findNearMissesForAllUnmatched() async throws -> [NearMiss] {
        try await admin.get("requests/unmatched/near-misses", as: FindNearMissesResult.self).nearMisses
    }

    /// The closest-matching stubs for a specific logged request.
    public func findNearMisses(for request: LoggedRequest) async throws -> [NearMiss] {
        try await admin.send("POST", "near-misses/request", body: request, as: FindNearMissesResult.self).nearMisses
    }

    /// The requests that came closest to matching the given pattern.
    public func findNearMisses(for builder: RequestPatternBuilder) async throws -> [NearMiss] {
        try await admin.send("POST", "near-misses/request-pattern", body: builder.pattern, as: FindNearMissesResult.self).nearMisses
    }
}

// MARK: - Scenarios

extension WireMock {
    /// All scenarios and their current states.
    public func getAllScenarios() async throws -> [Scenario] {
        try await admin.get("scenarios", as: GetScenariosResult.self).scenarios
    }

    /// Resets every scenario back to its initial (`Started`) state.
    public func resetAllScenarios() async throws {
        try await admin.send("POST", "scenarios/reset")
    }

    /// Forces a single scenario into the given state.
    public func setScenarioState(name: String, state: String) async throws {
        struct StateBody: Encodable { let state: String }
        try await admin.send("PUT", "scenarios/\(name)/state", body: StateBody(state: state))
    }

    /// Resets a single scenario back to its initial (`Started`) state.
    public func resetScenario(name: String) async throws {
        try await admin.send("PUT", "scenarios/\(name)/state")
    }
}

// MARK: - Global settings

extension WireMock {
    /// Replaces the global settings (delay distribution, proxy pass-through, …).
    public func updateGlobalSettings(_ settings: GlobalSettings) async throws {
        try await admin.send("POST", "settings", body: settings)
    }

    /// Applies a fixed delay (ms) to every response server-wide.
    public func setGlobalFixedDelay(_ milliseconds: Int) async throws {
        try await updateGlobalSettings(GlobalSettings(fixedDelay: milliseconds))
    }

    /// Reads the current global settings. `GET /__admin/settings` wraps the
    /// object under a `settings` key; this unwraps it for you.
    public func getGlobalSettings() async throws -> GlobalSettings {
        struct Wrapper: Decodable { let settings: GlobalSettings }
        return try await admin.get("settings", as: Wrapper.self).settings
    }
}

// MARK: - Server info

extension WireMock {
    /// The server health endpoint (`GET /__admin/health`), returned verbatim.
    public func getHealth() async throws -> JSONValue {
        try await admin.get("health", as: JSONValue.self)
    }

    /// The running server's version (`GET /__admin/version`).
    public func getVersion() async throws -> String? {
        struct VersionResult: Decodable { let version: String? }
        return try await admin.get("version", as: VersionResult.self).version
    }
}

// MARK: - Unmatched stub mappings

extension WireMock {
    /// Stub mappings that have never been matched by any request.
    public func findUnmatchedStubMappings() async throws -> [StubMapping] {
        try await admin.get("mappings/unmatched", as: ListStubMappingsResult.self).mappings
    }

    /// Deletes all stub mappings that have never been matched.
    public func removeUnmatchedStubMappings() async throws {
        try await admin.send("DELETE", "mappings/unmatched")
    }
}

// MARK: - Record & playback

extension WireMock {
    /// Starts recording, proxying traffic to `spec.targetBaseUrl` and capturing
    /// it as stubs. Point the target at a SEPARATE upstream (self-proxy hangs).
    public func startRecording(_ spec: RecordSpec) async throws {
        try await admin.send("POST", "recordings/start", body: spec)
    }

    /// Starts recording against an upstream base URL with default options.
    public func startRecording(targetBaseUrl: String) async throws {
        try await startRecording(RecordSpec(targetBaseUrl: targetBaseUrl))
    }

    /// Stops recording and returns the stub mappings generated from the traffic.
    @discardableResult
    public func stopRecording() async throws -> [StubMapping] {
        try await admin.send("POST", "recordings/stop", body: EmptyBody(), as: SnapshotResult.self).mappings ?? []
    }

    /// The recorder state (`"NeverStarted"`, `"Recording"`, `"Stopped"`).
    public func getRecordingStatus() async throws -> String? {
        try await admin.get("recordings/status", as: RecordingStatusResult.self).status
    }

    /// Generates stubs from the requests already in the journal, without an
    /// active recording session; returns the generated mappings.
    @discardableResult
    public func takeSnapshot(_ spec: RecordSpec = RecordSpec()) async throws -> [StubMapping] {
        try await admin.send("POST", "recordings/snapshot", body: spec, as: SnapshotResult.self).mappings ?? []
    }
}

// MARK: - Files (__files)

extension WireMock {
    /// Lists file names under `__files`.
    public func listFiles() async throws -> [String] {
        let data = try await admin.send("GET", "files")
        // The server has returned both a bare array and a `{ "files": [...] }`
        // wrapper across versions — accept either.
        if let array = try? JSONDecoder().decode([String].self, from: data) {
            return array
        }
        struct Wrapper: Decodable { let files: [String] }
        if let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapper.files
        }
        // Don't silently return "no files" for a body we failed to parse.
        throw WireMockError.decodingFailed(
            underlying: "listFiles: unexpected /__admin/files response: \(String(data: data, encoding: .utf8) ?? "<binary>")"
        )
    }

    /// Fetches the raw bytes of a `__files` entry.
    public func getFile(named name: String) async throws -> Data {
        try await admin.send("GET", "files/\(name)")
    }

    /// Uploads binary data as a `__files` entry (served via `withBodyFile`).
    public func putFile(named name: String, data: Data, contentType: String = "application/octet-stream") async throws {
        try await admin.sendData("PUT", "files/\(name)", body: data, contentType: contentType)
    }

    /// Uploads text as a `__files` entry (served via `withBodyFile`).
    public func putFile(named name: String, text: String, contentType: String = "text/plain") async throws {
        try await putFile(named: name, data: Data(text.utf8), contentType: contentType)
    }

    /// Deletes a `__files` entry.
    public func deleteFile(named name: String) async throws {
        try await admin.send("DELETE", "files/\(name)")
    }
}

// MARK: - Metadata & bulk import

extension WireMock {
    /// Finds stubs whose `metadata` satisfies the matcher (e.g. a JSONPath match).
    public func findStubsByMetadata(_ matcher: StringValuePattern) async throws -> [StubMapping] {
        try await admin.send("POST", "mappings/find-by-metadata", body: matcher, as: ListStubMappingsResult.self).mappings
    }

    /// Removes stubs whose `metadata` satisfies the matcher.
    public func removeStubsByMetadata(_ matcher: StringValuePattern) async throws {
        try await admin.send("POST", "mappings/remove-by-metadata", body: matcher)
    }

    /// Registers many stub mappings in one call.
    public func importMappings(_ mappings: [StubMapping]) async throws {
        struct ImportBody: Encodable { let mappings: [StubMapping] }
        try await admin.send("POST", "mappings/import", body: ImportBody(mappings: mappings))
    }
}

/// An empty JSON object body for endpoints that require a body but no fields.
struct EmptyBody: Encodable {}
