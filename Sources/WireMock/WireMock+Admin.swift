import Foundation

// MARK: - Verification & request journal

extension WireMock {
    /// Counts journalled requests matching the builder.
    public func count(_ builder: RequestPatternBuilder) throws -> Int {
        try countRequests(matching: builder.pattern)
    }

    /// Asserts at least one request matched (`verify(pattern)` in Java).
    public func verify(_ builder: RequestPatternBuilder) throws {
        try verify(.moreThanOrExactly(1), builder)
    }

    /// Asserts exactly `count` requests matched (`verify(count, pattern)` in Java).
    public func verify(_ count: Int, _ builder: RequestPatternBuilder) throws {
        try verify(.exactly(count), builder)
    }

    /// Asserts the matching-request count satisfies `strategy`.
    public func verify(_ strategy: CountMatchingStrategy, _ builder: RequestPatternBuilder) throws {
        try reporter.step("Verify (\(strategy)): \(RequestExpectation.summary(builder))",
                          jsonBody: builder.description) {
            let actual = try count(builder)
            guard strategy.isSatisfied(by: actual) else {
                // On a shortfall (fewer matches than expected), pull the closest
                // near-misses so the thrown error carries a diff report, like Java's
                // VerificationException. Best-effort: a disabled journal or a failed
                // lookup falls back to the bare count rather than masking the real
                // assertion failure with a secondary error.
                let nearMisses = strategy.isShortfall(actual) ? ((try? findNearMisses(for: builder)) ?? []) : []
                throw VerificationError(expected: strategy.description, actual: actual, nearMisses: nearMisses)
            }
        }
    }

    /// Returns all journalled requests matching the builder.
    public func findAll(_ builder: RequestPatternBuilder) throws -> [LoggedRequest] {
        let result = try admin.send("POST", "requests/find", body: builder.pattern, as: FindRequestsResult.self)
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    /// All serve events in the journal (most recent first).
    public func getAllServeEvents() throws -> [ServeEvent] {
        let result = try admin.get("requests", as: GetServeEventsResult.self)
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    /// Serve events with server-side filtering (`limit`, `since`, unmatched-only,
    /// or by the stub mapping that matched them).
    public func getServeEvents(
        limit: Int? = nil,
        since: String? = nil,
        unmatchedOnly: Bool = false,
        matchingStub: UUID? = nil
    ) throws -> [ServeEvent] {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if unmatchedOnly { query.append(URLQueryItem(name: "unmatched", value: "true")) }
        if let matchingStub { query.append(URLQueryItem(name: "matchingStub", value: matchingStub.uuidString)) }
        let result = try admin.get("requests", query: query, as: GetServeEventsResult.self)
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    /// Serve events since a specific moment, type-safe alternative to the `String`
    /// overload: `since` is formatted as an ISO-8601 instant (`2024-06-01T12:00:00Z`),
    /// the format the server expects. Use the `String` overload for a pre-formatted
    /// value in a non-default shape.
    public func getServeEvents(
        limit: Int? = nil,
        since: Date,
        unmatchedOnly: Bool = false,
        matchingStub: UUID? = nil
    ) throws -> [ServeEvent] {
        try getServeEvents(limit: limit, since: since.ISO8601Format(),
                           unmatchedOnly: unmatchedOnly, matchingStub: matchingStub)
    }

    /// A single serve event by id.
    public func getServeEvent(id: UUID) throws -> ServeEvent {
        try admin.get("requests/\(id.uuidString)", as: ServeEvent.self)
    }

    /// Removes a single serve event from the journal.
    public func removeServeEvent(id: UUID) throws {
        try admin.send("DELETE", "requests/\(id.uuidString)")
    }

    /// Clears the entire request journal.
    public func resetRequests() throws {
        try admin.send("DELETE", "requests")
    }

    /// Removes journalled events matching the pattern; returns the removed events.
    @discardableResult
    public func removeServeEvents(matching builder: RequestPatternBuilder) throws -> [ServeEvent] {
        try admin.send("POST", "requests/remove", body: builder.pattern, as: RemovedServeEventsResult.self).serveEvents
    }

    /// Removes journalled events whose originating stub matches the metadata matcher.
    public func removeServeEventsByMetadata(_ matcher: StringValuePattern) throws {
        try admin.send("POST", "requests/remove-by-metadata", body: matcher)
    }

    /// Requests received that matched no stub.
    public func getUnmatchedRequests() throws -> [LoggedRequest] {
        let result = try admin.get("requests/unmatched", as: FindRequestsResult.self)
        // With the journal off the server returns an empty list; throw like the
        // sibling journal methods so an empty result isn't misread as "all matched".
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.requests
    }

    // MARK: Near misses

    /// The closest-matching stubs for every request that matched nothing.
    public func findNearMissesForAllUnmatched() throws -> [NearMiss] {
        try admin.get("requests/unmatched/near-misses", as: FindNearMissesResult.self).nearMisses
    }

    /// The closest-matching stubs for a specific logged request.
    public func findNearMisses(for request: LoggedRequest) throws -> [NearMiss] {
        try admin.send("POST", "near-misses/request", body: request, as: FindNearMissesResult.self).nearMisses
    }

    /// The requests that came closest to matching the given pattern.
    public func findNearMisses(for builder: RequestPatternBuilder) throws -> [NearMiss] {
        try admin.send("POST", "near-misses/request-pattern", body: builder.pattern, as: FindNearMissesResult.self).nearMisses
    }
}

// MARK: - Scenarios

extension WireMock {
    /// All scenarios and their current states.
    public func getAllScenarios() throws -> [Scenario] {
        try admin.get("scenarios", as: GetScenariosResult.self).scenarios
    }

    /// Resets every scenario back to its initial (`Started`) state.
    public func resetAllScenarios() throws {
        try admin.send("POST", "scenarios/reset")
    }

    /// Forces a single scenario into the given state.
    public func setScenarioState(name: String, state: String) throws {
        struct StateBody: Encodable { let state: String }
        let segment = try AdminClient.pathSegment(name)
        try admin.send("PUT", "scenarios/\(segment)/state", body: StateBody(state: state))
    }

    /// Resets a single scenario back to its initial (`Started`) state.
    public func resetScenario(name: String) throws {
        let segment = try AdminClient.pathSegment(name)
        try admin.send("PUT", "scenarios/\(segment)/state")
    }
}

// MARK: - Global settings

extension WireMock {
    /// Replaces the global settings (delay distribution, proxy pass-through, …).
    public func updateGlobalSettings(_ settings: GlobalSettings) throws {
        try admin.send("POST", "settings", body: settings)
    }

    /// Applies a fixed delay (ms) to every response server-wide.
    public func setGlobalFixedDelay(_ milliseconds: Int) throws {
        try updateGlobalSettings(GlobalSettings(fixedDelay: milliseconds))
    }

    /// Applies a random delay distribution to every response server-wide.
    public func setGlobalRandomDelay(_ distribution: DelayDistribution) throws {
        try updateGlobalSettings(GlobalSettings(delayDistribution: distribution))
    }

    /// Reads the current global settings. `GET /__admin/settings` wraps the
    /// object under a `settings` key; this unwraps it for you.
    public func getGlobalSettings() throws -> GlobalSettings {
        struct Wrapper: Decodable { let settings: GlobalSettings }
        return try admin.get("settings", as: Wrapper.self).settings
    }
}

// MARK: - Server info

extension WireMock {
    /// The server health endpoint (`GET /__admin/health`), returned verbatim.
    public func getHealth() throws -> JSONValue {
        try admin.get("health", as: JSONValue.self)
    }

    /// The running server's version (`GET /__admin/version`).
    public func getVersion() throws -> String? {
        struct VersionResult: Decodable { let version: String? }
        return try admin.get("version", as: VersionResult.self).version
    }
}

// MARK: - Unmatched stub mappings

extension WireMock {
    /// Stub mappings that have never been matched by any request.
    public func findUnmatchedStubMappings() throws -> [StubMapping] {
        try admin.get("mappings/unmatched", as: ListStubMappingsResult.self).mappings
    }

    /// Deletes all stub mappings that have never been matched.
    public func removeUnmatchedStubMappings() throws {
        try admin.send("DELETE", "mappings/unmatched")
    }
}

// MARK: - Record & playback

extension WireMock {
    /// Starts recording, proxying traffic to `spec.targetBaseUrl` and capturing
    /// it as stubs. Point the target at a SEPARATE upstream (self-proxy hangs).
    public func startRecording(_ spec: RecordSpec) throws {
        try admin.send("POST", "recordings/start", body: spec)
    }

    /// Starts recording against an upstream base URL with default options.
    public func startRecording(targetBaseUrl: String) throws {
        try startRecording(RecordSpec(targetBaseUrl: targetBaseUrl))
    }

    /// Stops recording and returns the stub mappings generated from the traffic.
    @discardableResult
    public func stopRecording() throws -> [StubMapping] {
        try admin.send("POST", "recordings/stop", body: EmptyBody(), as: SnapshotResult.self).mappings ?? []
    }

    /// The recorder state (`"NeverStarted"`, `"Recording"`, `"Stopped"`).
    public func getRecordingStatus() throws -> String? {
        try admin.get("recordings/status", as: RecordingStatusResult.self).status
    }

    /// Generates stubs from the requests already in the journal, without an
    /// active recording session; returns the generated mappings.
    @discardableResult
    public func takeSnapshot(_ spec: RecordSpec = RecordSpec()) throws -> [StubMapping] {
        try admin.send("POST", "recordings/snapshot", body: spec, as: SnapshotResult.self).mappings ?? []
    }

    /// Like `takeSnapshot`, but requests `outputFormat = "ids"` and returns the
    /// generated stub-mapping ids instead of the full mappings.
    @discardableResult
    public func takeSnapshotIds(_ spec: RecordSpec = RecordSpec()) throws -> [String] {
        var spec = spec
        spec.outputFormat = "ids"
        return try admin.send("POST", "recordings/snapshot", body: spec, as: SnapshotResult.self).ids ?? []
    }
}

// MARK: - Files (__files)

extension WireMock {
    /// Lists file names under `__files`.
    public func listFiles() throws -> [String] {
        // The server has returned both a bare array and a `{ "files": [...] }`
        // wrapper across versions — accept either. Routed through the shared
        // cached decoder/error path (a decode miss surfaces the raw body).
        try admin.get("files", as: FilesResult.self).files
    }

    /// Fetches the raw bytes of a `__files` entry.
    public func getFile(named name: String) throws -> Data {
        try admin.send("GET", "files/\(AdminClient.pathSegment(name))")
    }

    /// Uploads binary data as a `__files` entry (served via `withBodyFile`).
    public func putFile(named name: String, data: Data, contentType: String = "application/octet-stream") throws {
        try admin.sendData("PUT", "files/\(AdminClient.pathSegment(name))", body: data, contentType: contentType)
    }

    /// Uploads text as a `__files` entry (served via `withBodyFile`).
    public func putFile(named name: String, text: String, contentType: String = "text/plain") throws {
        try putFile(named: name, data: Data(text.utf8), contentType: contentType)
    }

    /// Deletes a `__files` entry.
    public func deleteFile(named name: String) throws {
        try admin.send("DELETE", "files/\(AdminClient.pathSegment(name))")
    }
}

// MARK: - Metadata & bulk import

extension WireMock {
    /// Finds stubs whose `metadata` satisfies the matcher (e.g. a JSONPath match).
    public func findStubsByMetadata(_ matcher: StringValuePattern) throws -> [StubMapping] {
        try admin.send("POST", "mappings/find-by-metadata", body: matcher, as: ListStubMappingsResult.self).mappings
    }

    /// Removes stubs whose `metadata` satisfies the matcher.
    public func removeStubsByMetadata(_ matcher: StringValuePattern) throws {
        try admin.send("POST", "mappings/remove-by-metadata", body: matcher)
    }

    /// How `importMappings` treats a mapping whose id already exists.
    public enum DuplicatePolicy: String, Sendable {
        case overwrite = "OVERWRITE"
        case ignore = "IGNORE"
    }

    /// Registers many stub mappings in one call.
    ///
    /// - Parameters:
    ///   - duplicatePolicy: whether an imported mapping overwrites or is ignored
    ///     when its id already exists (server default: overwrite).
    ///   - deleteAllNotInImport: if `true`, remove existing stubs absent from
    ///     this import.
    public func importMappings(
        _ mappings: [StubMapping],
        duplicatePolicy: DuplicatePolicy? = nil,
        deleteAllNotInImport: Bool? = nil
    ) throws {
        struct ImportOptions: Encodable { let duplicatePolicy: String?; let deleteAllNotInImport: Bool? }
        struct ImportBody: Encodable { let mappings: [StubMapping]; let importOptions: ImportOptions? }
        // When we send `importOptions` at all we must include `deleteAllNotInImport`:
        // WireMock 3.13.2 unconditionally unboxes it server-side, so omitting it
        // (e.g. `duplicatePolicy: .ignore` alone) triggers a 500 NullPointerException.
        // Default it to `false` (the server's own default) so a bare duplicatePolicy
        // call is safe.
        let options = (duplicatePolicy != nil || deleteAllNotInImport != nil)
            ? ImportOptions(duplicatePolicy: duplicatePolicy?.rawValue,
                            deleteAllNotInImport: deleteAllNotInImport ?? false)
            : nil
        try admin.send("POST", "mappings/import", body: ImportBody(mappings: mappings, importOptions: options))
    }
}

/// An empty JSON object body for endpoints that require a body but no fields.
struct EmptyBody: Encodable {}
