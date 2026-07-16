import Foundation

/// A fluent, BDD-style expectation over the requests matching a pattern.
///
/// Created by ``WireMock/expect(_:)``. Chain `to*` / `toNot*` checks (each
/// refines the pattern and re-verifies server-side), then optionally finish with
/// a terminal (`single`/`first`/`last`/`all`/`extract`) that inspects the
/// captured request(s) client-side. Every check is `throws` and returns `Self`,
/// so one `try` covers the whole chain.
public struct RequestExpectation: Sendable {
    private let wireMock: WireMock
    private var builder: RequestPatternBuilder
    /// The count expectation the field checks are held to. Defaults to "at least
    /// one", so `expect(x).toHaveHeader(...)` means "some request matched, with
    /// this header". `toHaveBeenSent` overrides it.
    private var countSpec: CountSpec

    init(wireMock: WireMock, builder: RequestPatternBuilder) {
        self.wireMock = wireMock
        self.builder = builder
        self.countSpec = .atLeast(1)
    }

    // MARK: - Count

    /// Asserts how many requests matched. Sets the expectation that subsequent
    /// field checks are held to.
    @discardableResult
    public func toHaveBeenSent(_ spec: CountSpec = .atLeast(1)) throws -> RequestExpectation {
        let actual = try wireMock.count(builder)
        guard spec.isSatisfied(by: actual) else {
            throw makeError(builder, actual: actual, check: nil, spec: spec)
        }
        var copy = self
        copy.countSpec = spec
        return copy
    }

    /// Alias for `toHaveBeenSent(.once)`.
    @discardableResult
    public func toHaveBeenSentOnce() throws -> RequestExpectation { try toHaveBeenSent(.once) }

    /// Alias for `toHaveBeenSent(.never)`.
    @discardableResult
    public func toNeverHaveBeenSent() throws -> RequestExpectation { try toHaveBeenSent(.never) }

    // MARK: - Headers / query / cookies / form (server-delegated)

    /// Requires a matching request whose `name` header satisfies `matcher`.
    @discardableResult
    public func toHaveHeader(_ name: String, _ matcher: StringValuePattern) throws -> RequestExpectation {
        try refine("header \(name)") { $0.withHeader(name, matcher) }
    }

    /// Requires that **no** matching request carries the `name` header (any value).
    @discardableResult
    public func toNotHaveHeader(_ name: String) throws -> RequestExpectation {
        try refineNegative("no header \(name)",
                           present: { $0.withHeader(name, Self.present) },
                           absent: { $0.withoutHeader(name) })
    }

    /// Requires a matching request whose `name` query parameter satisfies `matcher`.
    @discardableResult
    public func toHaveQueryParam(_ name: String, _ matcher: StringValuePattern) throws -> RequestExpectation {
        try refine("query param \(name)") { $0.withQueryParam(name, matcher) }
    }

    /// Requires that **no** matching request carries the `name` query parameter.
    @discardableResult
    public func toNotHaveQueryParam(_ name: String) throws -> RequestExpectation {
        try refineNegative("no query param \(name)",
                           present: { $0.withQueryParam(name, Self.present) },
                           absent: { $0.withoutQueryParam(name) })
    }

    /// Requires a matching request whose `name` cookie satisfies `matcher`.
    @discardableResult
    public func toHaveCookie(_ name: String, _ matcher: StringValuePattern) throws -> RequestExpectation {
        try refine("cookie \(name)") { $0.withCookie(name, matcher) }
    }

    /// Requires that **no** matching request carries the `name` cookie.
    @discardableResult
    public func toNotHaveCookie(_ name: String) throws -> RequestExpectation {
        try refineNegative("no cookie \(name)",
                           present: { $0.withCookie(name, Self.present) },
                           absent: { $0.withCookie(name, .absent) })
    }

    /// Requires a matching request whose `name` form-body parameter satisfies `matcher`.
    @discardableResult
    public func toHaveFormParam(_ name: String, _ matcher: StringValuePattern) throws -> RequestExpectation {
        try refine("form param \(name)") { $0.withFormParam(name, matcher) }
    }

    /// Requires that **no** matching request carries the `name` form-body parameter.
    ///
    /// Hardened against a content-type footgun: WireMock only parses (and matches)
    /// `formParameters` when the request carried
    /// `Content-Type: application/x-www-form-urlencoded`, so a form-encoded body
    /// sent **without** that content type would slip past the server-side check and
    /// leak the param (a real risk for a security negative like
    /// `toNotHaveFormParam("client_secret")`). So after the server-side "count the
    /// offenders is 0" check, this also scans the captured request bodies
    /// client-side (content-type-agnostic, like ``CapturedRequest/formItems()``) and
    /// fails if any actually carries `name` in its body.
    @discardableResult
    public func toNotHaveFormParam(_ name: String) throws -> RequestExpectation {
        let refined = try refineNegative("no form param \(name)",
                                         present: { $0.withFormParam(name, Self.present) },
                                         absent: { $0.withoutFormParam(name) })
        let leaking = try wireMock.findAll(builder)
            .map(CapturedRequest.init)
            .filter { req in
                guard let body = req.bodyString, !body.isEmpty else { return false }
                // Skip only recognisably structured data (valid JSON, or a body that
                // opens with `{`/`[`/`<`): its incidental "&name=" substrings would
                // fabricate a phantom form param and false-fail this negative. Every
                // other body is decoded form-wise. This is deliberately a *blacklist*
                // (skip JSON/XML) rather than a strict character allowlist: a real
                // form-encoded leak whose value isn't percent-encoded — e.g. a raw
                // `redirect_uri=https://app/cb`, whose `:`/`/` an allowlist rejects —
                // must still be caught, or the content-type-evading secret leak this
                // scan exists to find would be silently missed.
                if Self.looksStructuredNonForm(body, json: req.bodyJSON) { return false }
                return req.formItems().contains { $0.name == name }
            }
        guard leaking.isEmpty else {
            var message = "Expected no form param \(name) on any request matching \(Self.summary(builder)), "
                + "but \(leaking.count) carried it in the body — a form-encoded body sent without an "
                + "application/x-www-form-urlencoded Content-Type evades server-side form matching:"
            for (index, req) in leaking.enumerated() {
                message += "\n  #\(index + 1)  \(Self.compactLine(req.logged))"
            }
            throw RequestExpectationError(message: message)
        }
        return refined
    }

    // MARK: - Presence (name only, any value)

    /// Requires the header to be present with **any** value (including empty).
    /// For a non-empty value use the matcher overload with `.matching(".+")`.
    @discardableResult
    public func toHaveHeader(_ name: String) throws -> RequestExpectation {
        try refine("header \(name)") { $0.withHeader(name, Self.present) }
    }

    /// Requires the query parameter to be present with **any** value (including
    /// empty) — e.g. `state`/`nonce` on an OAuth `/authorize` request. For a
    /// non-empty value use the matcher overload with `.matching(".+")`.
    @discardableResult
    public func toHaveQueryParam(_ name: String) throws -> RequestExpectation {
        try refine("query param \(name)") { $0.withQueryParam(name, Self.present) }
    }

    /// Requires the cookie to be present with **any** value (including empty).
    /// For a non-empty value use the matcher overload with `.matching(".+")`.
    @discardableResult
    public func toHaveCookie(_ name: String) throws -> RequestExpectation {
        try refine("cookie \(name)") { $0.withCookie(name, Self.present) }
    }

    /// Requires the form parameter to be present with **any** value (including
    /// empty) — e.g. `code_verifier` on an OAuth `/token` request. For a
    /// non-empty value use the matcher overload with `.matching(".+")`.
    @discardableResult
    public func toHaveFormParam(_ name: String) throws -> RequestExpectation {
        try refine("form param \(name)") { $0.withFormParam(name, Self.present) }
    }

    /// The matcher used by the presence-only overloads: any value is accepted,
    /// but the key must exist (WireMock treats a missing key as a non-match when
    /// a value matcher is specified). `.*` also accepts an empty value.
    private static let present: StringValuePattern = .matching(".*")

    // MARK: - Auth

    /// Requires an `Authorization: Bearer <token>` header (exact token).
    @discardableResult
    public func toHaveBearerToken(_ token: String) throws -> RequestExpectation {
        try refine("bearer token") { $0.withHeader("Authorization", .equalTo("Bearer \(token)")) }
    }

    /// Requires an `Authorization: Bearer …` header whose token matches the
    /// given regex (the `Bearer ` prefix is added for you). Matching is
    /// whole-string, so the regex covers just the token — do **not** add a `^`
    /// anchor (it would land after `Bearer ` and never match).
    @discardableResult
    public func toHaveBearerToken(matching pattern: String) throws -> RequestExpectation {
        try refine("bearer token") { $0.withHeader("Authorization", .matching("Bearer \(pattern)")) }
    }

    /// Requires an `Authorization: Basic …` header for these credentials.
    @discardableResult
    public func toHaveBasicAuth(username: String, password: String) throws -> RequestExpectation {
        try refine("basic auth") { $0.withBasicAuth(username: username, password: password) }
    }

    // MARK: - Body

    /// General body matcher (`equalTo` / `containing` / `matching`, …).
    @discardableResult
    public func toHaveBody(_ matcher: StringValuePattern) throws -> RequestExpectation {
        try refine("body") { $0.withRequestBody(matcher) }
    }

    /// Requires the body to equal `value` exactly.
    @discardableResult
    public func toHaveBody(equalTo value: String) throws -> RequestExpectation {
        try refine("body") { $0.withRequestBody(.equalTo(value)) }
    }

    /// Requires the body to contain `substring`.
    @discardableResult
    public func toHaveBody(containing substring: String) throws -> RequestExpectation {
        try refine("body contains \(substring)") { $0.withRequestBody(.containing(substring)) }
    }

    /// Requires the body to match the given regex.
    @discardableResult
    public func toHaveBody(matching regex: String) throws -> RequestExpectation {
        try refine("body matches \(regex)") { $0.withRequestBody(.matching(regex)) }
    }

    /// Requires an absent/empty request body.
    ///
    /// Uses WireMock's `absent`, which is satisfied by both "no body" and an
    /// empty string and does not distinguish them. Use `toHaveNonEmptyBody()`
    /// for the opposite.
    @discardableResult
    public func toHaveEmptyBody() throws -> RequestExpectation {
        try refine("empty body") { $0.withRequestBody(.absent) }
    }

    /// Requires a non-empty request body (at least one character). Note this
    /// counts a whitespace-only body (e.g. `" "`) as non-empty — it is a literal
    /// "≥1 char" check, not a trimmed one.
    @discardableResult
    public func toHaveNonEmptyBody() throws -> RequestExpectation {
        try refine("non-empty body") { $0.withRequestBody(.matching("[\\s\\S]+")) }
    }

    /// Requires the JSON body to contain the given JSONPath (value unchecked).
    @discardableResult
    public func toHaveJsonPath(_ path: String) throws -> RequestExpectation {
        try refine("json path \(path)") { $0.withRequestBody(.matchingJsonPath(path)) }
    }

    /// Requires the value at JSONPath `path` to satisfy `matcher`
    /// (pairs with `toHaveJsonPath(_:)`, which only checks existence).
    ///
    /// The server compares the extracted value as a string, so match a JSON
    /// number by its string form: `toHaveJsonPath("$.qty", equalTo("2"))`
    /// (not `equalTo(2)`, which doesn't compile).
    @discardableResult
    public func toHaveJsonPath(_ path: String, _ matcher: StringValuePattern) throws -> RequestExpectation {
        try refine("json path \(path)") { $0.withRequestBody(.matchingJsonPath(path, matcher)) }
    }

    /// Full JSON body comparison. `ignoreExtraElements: true` accepts extra
    /// fields ("вхождение"); the default is a strict full match.
    @discardableResult
    public func toHaveJsonBody(
        equalTo json: JSONValue,
        ignoreExtraElements: Bool = false,
        ignoreArrayOrder: Bool = false
    ) throws -> RequestExpectation {
        try refine("json body") {
            $0.withRequestBody(.equalToJson(json, ignoreArrayOrder: ignoreArrayOrder, ignoreExtraElements: ignoreExtraElements))
        }
    }

    /// Full JSON body comparison from a raw JSON string (validated up front).
    @discardableResult
    public func toHaveJsonBody(
        equalToRaw json: String,
        ignoreExtraElements: Bool = false,
        ignoreArrayOrder: Bool = false
    ) throws -> RequestExpectation {
        let matcher: StringValuePattern
        do {
            matcher = try StringValuePattern.equalToJson(raw: json, ignoreArrayOrder: ignoreArrayOrder, ignoreExtraElements: ignoreExtraElements)
        } catch {
            // Keep the layer's "only RequestExpectationError escapes" contract: the
            // underlying `equalToJson(raw:)` throws WireMockError on malformed JSON,
            // which the file/bundle overloads (and callers) shouldn't have to catch.
            throw RequestExpectationError(message: "toHaveJsonBody(equalToRaw:) was given invalid JSON")
        }
        return try refine("json body") { $0.withRequestBody(matcher) }
    }

    /// Full JSON body comparison against the contents of a file URL.
    @discardableResult
    public func toHaveJsonBody(
        equalToFile url: URL,
        ignoreExtraElements: Bool = false,
        ignoreArrayOrder: Bool = false
    ) throws -> RequestExpectation {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Wrap the raw Foundation read error so both file overloads fail with
            // the layer's own error type (the bundle overload already does).
            throw RequestExpectationError(message: "Cannot read JSON file at \(url.path): \(error.localizedDescription)")
        }
        return try toHaveJsonBody(equalToRaw: text, ignoreExtraElements: ignoreExtraElements, ignoreArrayOrder: ignoreArrayOrder)
    }

    /// Full JSON body comparison against a bundled resource
    /// (e.g. `toHaveJsonBody(equalToFile: "order", bundle: .module)`).
    ///
    /// Pass `subdirectory:` when the resource keeps a folder structure in the
    /// bundle (e.g. `.copy("Fixtures")` in `Package.swift` →
    /// `subdirectory: "Fixtures"`).
    @discardableResult
    public func toHaveJsonBody(
        equalToFile name: String,
        withExtension ext: String = "json",
        subdirectory: String? = nil,
        bundle: Bundle,
        ignoreExtraElements: Bool = false,
        ignoreArrayOrder: Bool = false
    ) throws -> RequestExpectation {
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw RequestExpectationError(message: "JSON fixture '\(name).\(ext)' not found in bundle at \(bundle.bundlePath)")
        }
        return try toHaveJsonBody(equalToFile: url, ignoreExtraElements: ignoreExtraElements, ignoreArrayOrder: ignoreArrayOrder)
    }

    /// Validates the JSON body against a JSON Schema.
    @discardableResult
    public func toHaveJsonBody(
        matchingSchema schema: JSONValue,
        version: StringValuePattern.JSONSchemaVersion? = nil
    ) throws -> RequestExpectation {
        try refine("json schema") { $0.withRequestBody(.matchingJsonSchema(schema, version: version)) }
    }

    /// Full XML body comparison, forwarding WireMock's `equalToXml` options
    /// (placeholders, node-order, namespace awareness).
    @discardableResult
    public func toHaveXmlBody(
        equalTo xml: String,
        enablePlaceholders: Bool = false,
        placeholderOpeningDelimiterRegex: String? = nil,
        placeholderClosingDelimiterRegex: String? = nil,
        exemptedComparisons: [String]? = nil,
        ignoreOrderOfSameNode: Bool? = nil,
        namespaceAwareness: StringValuePattern.NamespaceAwareness? = nil
    ) throws -> RequestExpectation {
        try refine("xml body") {
            $0.withRequestBody(.equalToXml(
                xml,
                enablePlaceholders: enablePlaceholders,
                placeholderOpeningDelimiterRegex: placeholderOpeningDelimiterRegex,
                placeholderClosingDelimiterRegex: placeholderClosingDelimiterRegex,
                exemptedComparisons: exemptedComparisons,
                ignoreOrderOfSameNode: ignoreOrderOfSameNode,
                namespaceAwareness: namespaceAwareness
            ))
        }
    }

    /// Requires the XML body to satisfy the given XPath expression.
    @discardableResult
    public func toHaveBody(matchingXPath expression: String, namespaces: [String: String] = [:]) throws -> RequestExpectation {
        try refine("xpath \(expression)") { $0.withRequestBody(.matchingXPath(expression, namespaces: namespaces)) }
    }

    /// Requires the value extracted by the XPath to satisfy `matcher`.
    @discardableResult
    public func toHaveBody(matchingXPath expression: String, _ matcher: StringValuePattern, namespaces: [String: String] = [:]) throws -> RequestExpectation {
        try refine("xpath \(expression)") { $0.withRequestBody(.matchingXPath(expression, matcher, namespaces: namespaces)) }
    }

    // MARK: - Exact query-param set (client-side)

    /// Requires the matching request(s) to carry EXACTLY these query params —
    /// any extra param (e.g. a stray `?debug=true`) fails. WireMock's server-side
    /// matching is "contains", so this is evaluated on the captured request(s).
    @discardableResult
    public func toHaveExactlyQueryParams(_ params: [String: String]) throws -> RequestExpectation {
        try assertExactly(params, kind: "query params") { $0.queryItems() }
    }

    /// Requires the matching request(s) to carry EXACTLY these form-body params —
    /// any extra param fails. The form counterpart of `toHaveExactlyQueryParams`;
    /// the token endpoint's `application/x-www-form-urlencoded` body is the prime
    /// place to prove no extra field (e.g. a `client_secret`) leaked into the body.
    @discardableResult
    public func toHaveExactlyFormParams(_ params: [String: String]) throws -> RequestExpectation {
        try assertExactly(params, kind: "form params") { $0.formItems() }
    }

    /// Shared exact-set check for query/form params: every matching request must
    /// carry precisely `params` (same keys, each with exactly the one given
    /// value) as decoded by `items`.
    private func assertExactly(
        _ params: [String: String],
        kind: String,
        items: (CapturedRequest) -> [URLQueryItem]
    ) throws -> RequestExpectation {
        let requests = try fetchSorted()
        guard !requests.isEmpty else {
            // Report against the `.atLeast(1)` floor, not the declared `countSpec`:
            // an upper-bound-only spec (`.atMost`/`.lessThan`) is *satisfied* by 0, so
            // "Expected at most 3 … found 0" would misattribute the failure. The real
            // reason is there is no request to check the exact param set on. Mirrors
            // `refine`'s effectiveSpec handling.
            throw makeError(builder, actual: 0, check: "exact \(kind)", spec: .atLeast(1))
        }
        for req in requests {
            var actual: [String: [String]] = [:]
            for item in items(req) { actual[item.name, default: []].append(item.value ?? "") }
            if Set(params.keys) != Set(actual.keys) {
                throw RequestExpectationError(
                    message: "Expected exactly \(kind) \(params.keys.sorted()) on \(req.method?.description ?? "?") \(req.url ?? "?"), but had \(actual.keys.sorted())"
                )
            }
            for (key, value) in params where actual[key] != [value] {
                throw RequestExpectationError(
                    message: "Expected \(kind.dropLast()) '\(key)'=\(value) but was \(actual[key] ?? []) on \(req.url ?? "?")"
                )
            }
        }
        return self
    }

    // MARK: - Terminals (client-side capture)

    /// The single matching request. Throws if the count is not exactly one.
    public func single() throws -> CapturedRequest {
        let all = try fetchSorted()
        guard all.count == 1 else {
            throw RequestExpectationError(message: "Expected exactly one request matching \(Self.summary(builder)), but found \(all.count)" + dump(all))
        }
        return all[0]
    }

    /// The earliest matching request (by `loggedDate`). Throws if none matched.
    public func first() throws -> CapturedRequest {
        guard let first = try fetchSorted().first else { throw notFound() }
        return first
    }

    /// The latest matching request (by `loggedDate`). Throws if none matched.
    public func last() throws -> CapturedRequest {
        guard let last = try fetchSorted().last else { throw notFound() }
        return last
    }

    /// All matching requests, oldest first.
    public func all() throws -> [CapturedRequest] {
        try fetchSorted()
    }

    /// Extract a value from the single matching request (for correlation across
    /// requests). Throws if the count is not exactly one.
    public func extract() throws -> RequestExtractor {
        try single().extract()
    }

    // MARK: - Internals

    /// Applies a matcher to the pattern, re-counts server-side, and validates the
    /// count still satisfies `countSpec`; on failure names the just-added check.
    ///
    /// A positive field check also requires the narrowed count to be **at least
    /// one** — otherwise an upper-bound-only spec (`.atMost`/`.lessThan`, which is
    /// satisfied by 0) would make the assertion vacuous: `toHaveBeenSent(.atMost(5))
    /// .toHaveHeader("Authorization")` would pass even if no request carried the
    /// header. When only that floor fails (the declared spec is otherwise
    /// satisfied), the error is reported against the `.atLeast(1)` floor.
    private func refine(_ check: String, _ transform: (RequestPatternBuilder) -> RequestPatternBuilder) throws -> RequestExpectation {
        let refined = transform(builder)
        let actual = try wireMock.count(refined)
        guard actual >= 1, countSpec.isSatisfied(by: actual) else {
            let effectiveSpec = countSpec.isSatisfied(by: actual) ? CountSpec.atLeast(1) : countSpec
            throw makeError(refined, actual: actual, check: check, spec: effectiveSpec)
        }
        var copy = self
        copy.builder = refined
        return copy
    }

    /// The negative counterpart of ``refine(_:_:)``: asserts that **no** request
    /// matching the current pattern carries the field, by counting the requests
    /// that *do* (the pattern narrowed by the positive matcher) and requiring
    /// zero.
    ///
    /// This is deliberately stronger than "narrow by the absent matcher and check
    /// the count still satisfies `countSpec`": that weaker reading passes as long
    /// as *some* request lacked the field, silently tolerating a second request
    /// that leaked it — a real footgun for a security negative like
    /// `toNotHaveQueryParam("client_secret")`. The builder is still narrowed by
    /// the absent matcher for any subsequent chained checks.
    private func refineNegative(
        _ check: String,
        present presentTransform: (RequestPatternBuilder) -> RequestPatternBuilder,
        absent absentTransform: (RequestPatternBuilder) -> RequestPatternBuilder
    ) throws -> RequestExpectation {
        // Floor, symmetric with `refine`: the base pattern must itself have matched
        // (default `.atLeast(1)`) before "no request carried the field" can mean
        // anything. Without it a negative passes VACUOUSLY when zero requests matched
        // — a typo'd URL or a flow that never ran turns a security negative like
        // `toNotHaveQueryParam("client_secret")` green, the same false-green the
        // positive floor exists to prevent. (A deliberate strengthening over Java,
        // whose `verify(never(), …)` is satisfied by zero requests; consistency
        // between `toHave*`/`toNot*` outweighs matching Java's laxer negative here.)
        let baseCount = try wireMock.count(builder)
        guard baseCount >= 1, countSpec.isSatisfied(by: baseCount) else {
            let effectiveSpec = countSpec.isSatisfied(by: baseCount) ? CountSpec.atLeast(1) : countSpec
            throw makeError(builder, actual: baseCount, check: check, spec: effectiveSpec)
        }
        let offending = presentTransform(builder)
        let count = try wireMock.count(offending)
        guard count == 0 else {
            var message = "Expected \(check) on any request matching \(Self.summary(builder)), but \(count) carried it"
            if let matched = try? wireMock.findAll(offending), !matched.isEmpty {
                message += ":"
                for (index, request) in matched.enumerated() {
                    message += "\n  #\(index + 1)  \(Self.compactLine(request))"
                }
            }
            throw RequestExpectationError(message: message)
        }
        var copy = self
        copy.builder = absentTransform(builder)
        return copy
    }

    private func fetchSorted() throws -> [CapturedRequest] {
        try wireMock.findAll(builder)
            .sorted { ($0.loggedDate ?? .max) < ($1.loggedDate ?? .max) }
            .map(CapturedRequest.init)
    }

    private func notFound() -> RequestExpectationError {
        RequestExpectationError(message: "Expected at least one request matching \(Self.summary(builder)), but found none")
    }

    /// Builds the failure message: reuses `VerificationError`'s near-miss diff on
    /// a shortfall; dumps every matching request on a "too many" failure.
    ///
    /// The `try?` lookups below are best-effort enrichment only. This runs after
    /// an assertion has already failed (the primary count succeeded), so if the
    /// journal is disabled here the near-miss/dump simply degrades to the bare
    /// message rather than masking the real failure with a secondary error — the
    /// loud `requestJournalDisabled` would have surfaced from the primary `count`.
    private func makeError(_ rb: RequestPatternBuilder, actual: Int, check: String?, spec: CountSpec) -> RequestExpectationError {
        let note = check.map { " (failing check: \($0))" } ?? ""
        if spec.isShortfall(actual) {
            let misses = (try? wireMock.findNearMisses(for: rb)) ?? []
            let rendered = VerificationError(expected: spec.description, actual: actual, nearMisses: misses).description
            return RequestExpectationError(message: rendered + note)
        }
        var message = "Expected \(spec.description) matching request(s) for \(Self.summary(rb)) but found \(actual)\(note)"
        if actual > 0, let matched = try? wireMock.findAll(rb), !matched.isEmpty {
            message += ":"
            for (index, request) in matched.enumerated() {
                message += "\n  #\(index + 1)  \(Self.compactLine(request))"
            }
        }
        return RequestExpectationError(message: message)
    }

    private func dump(_ requests: [CapturedRequest]) -> String {
        guard !requests.isEmpty else { return "" }
        return ":" + requests.enumerated().map { "\n  #\($0.offset + 1)  \(Self.compactLine($0.element.logged))" }.joined()
    }

    /// A compact "METHOD url" summary of the pattern for messages.
    static func summary(_ builder: RequestPatternBuilder) -> String {
        let pattern = builder.pattern
        let method = pattern.method?.description ?? "ANY"
        let url = pattern.url ?? pattern.urlPattern ?? pattern.urlPath
            ?? pattern.urlPathPattern ?? pattern.urlPathTemplate ?? "any URL"
        return "\(method) \(url)"
    }

    /// A one-line rendering of a logged request for the "too many" dump.
    static func compactLine(_ request: LoggedRequest) -> String {
        var line = "\(request.method?.description ?? "?") \(request.url ?? "?")"
        if let contentType = CapturedRequest(logged: request).header("Content-Type") {
            line += "  Content-Type=\(contentType)"
        }
        if let body = request.body, !body.isEmpty {
            let snippet = body.count > 80 ? String(body.prefix(80)) + "…" : body
            line += "  body=\(snippet)"
        }
        return line
    }

    /// Whether `body` is recognisably structured data (JSON or XML) rather than a
    /// form-urlencoded payload, and so must be skipped by the form-leak scan. A
    /// structured body's incidental `&key=` substrings would otherwise fabricate a
    /// phantom form param and false-fail a `toNotHaveFormParam` negative.
    ///
    /// A body counts as structured when it parses as valid JSON, or when its first
    /// non-whitespace character opens a JSON object/array (`{`/`[`) or an XML/HTML
    /// document (`<`) — covering malformed-but-clearly-structured bodies too. Any
    /// other body is treated as a candidate form payload and scanned, so a
    /// form-encoded secret leak carrying an un-percent-encoded value (whose reserved
    /// characters a strict allowlist would wrongly reject) is still caught.
    private static func looksStructuredNonForm(_ body: String, json: JSONValue?) -> Bool {
        if json != nil { return true }
        guard let first = body.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "[" || first == "<"
    }
}
