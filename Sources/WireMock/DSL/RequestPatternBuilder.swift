import Foundation

/// Builds a `RequestPattern` for verification and journal queries. Mirrors
/// WireMock's `getRequestedFor(...)` / `postRequestedFor(...)` DSL.
public struct RequestPatternBuilder: Sendable {
    public private(set) var pattern: RequestPattern

    init(method: HTTPMethod, url: UrlPattern) {
        var pattern = RequestPattern()
        pattern.method = method
        url.apply(to: &pattern)
        self.pattern = pattern
    }

    private func mutating(_ transform: (inout RequestPattern) -> Void) -> Self {
        var copy = self
        transform(&copy.pattern)
        return copy
    }

    /// Combines two matchers pinned to the same key. Repeated `withHeader`/
    /// `withQueryParam`/… calls on one name **accumulate** (logical AND) rather than
    /// the later call overwriting the earlier.
    ///
    /// This is a **deliberate divergence** from Java WireMock: Java's builder stores
    /// each key in a `Map`, so a second call on the same key silently drops the first
    /// (last-wins). Accumulating instead keeps every matcher the caller asked for —
    /// dropping one silently is a footgun. The wire shape stays one matcher object per
    /// key (`{"and":[…]}`, which the server accepts), and nested ANDs are flattened so
    /// N calls yield one N-element AND.
    ///
    /// - Warning: Accumulating *mutually-exclusive* matchers on one key yields an
    ///   unsatisfiable AND that matches nothing — so `verify(never(), …)` on it always
    ///   passes (a false green). The sharpest case is `.absent` (via `withoutHeader`/
    ///   `withoutQueryParam`/…) AND a value matcher: a key can't be both absent and
    ///   present. But `equalTo("a")` + `equalTo("b")` is equally contradictory, and
    ///   whether two matchers conflict is undecidable in general, so this is NOT
    ///   detected here — it's the caller's responsibility not to over-constrain one
    ///   key. In the `expect(...)` DSL such a contradiction instead surfaces as a
    ///   thrown failure via the base-match floor, not a silent pass.
    static func combined(_ existing: StringValuePattern, _ new: StringValuePattern) -> StringValuePattern {
        if existing.fields.count == 1, case .array(let members)? = existing.fields["and"] {
            return StringValuePattern(["and": .array(members + [new.asJSON])])
        }
        return .and([existing, new])
    }

    public func withHeader(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.headers = ($0.headers ?? [:]).merging([name: matcher], uniquingKeysWith: Self.combined) }
    }

    /// Adds several header matchers at once (Java `withHeaders`). Each entry
    /// accumulates with any existing matcher on the same name, like `withHeader`.
    public func withHeaders(_ matchers: [String: StringValuePattern]) -> Self {
        matchers.reduce(self) { $0.withHeader($1.key, $1.value) }
    }

    public func withoutHeader(_ name: String) -> Self {
        withHeader(name, .absent)
    }

    public func withQueryParam(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.queryParameters = ($0.queryParameters ?? [:]).merging([name: matcher], uniquingKeysWith: Self.combined) }
    }

    /// Adds several query-parameter matchers at once (Java `withQueryParams`).
    /// Each entry accumulates with any existing matcher on the same name.
    public func withQueryParams(_ matchers: [String: StringValuePattern]) -> Self {
        matchers.reduce(self) { $0.withQueryParam($1.key, $1.value) }
    }

    /// Requires the query parameter to be absent.
    public func withoutQueryParam(_ name: String) -> Self {
        withQueryParam(name, .absent)
    }

    public func withCookie(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.cookies = ($0.cookies ?? [:]).merging([name: matcher], uniquingKeysWith: Self.combined) }
    }

    public func withRequestBody(_ matcher: StringValuePattern) -> Self {
        mutating { $0.bodyPatterns = ($0.bodyPatterns ?? []) + [matcher] }
    }

    public func withBasicAuth(username: String, password: String) -> Self {
        mutating { $0.basicAuthCredentials = BasicAuthCredentials(username: username, password: password) }
    }

    public func withPathParam(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.pathParameters = ($0.pathParameters ?? [:]).merging([name: matcher], uniquingKeysWith: Self.combined) }
    }

    public func withFormParam(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.formParameters = ($0.formParameters ?? [:]).merging([name: matcher], uniquingKeysWith: Self.combined) }
    }

    /// Requires the form parameter to be absent.
    public func withoutFormParam(_ name: String) -> Self {
        withFormParam(name, .absent)
    }

    public func withMultipartRequestBody(_ part: MultipartValuePattern) -> Self {
        mutating { $0.multipartPatterns = ($0.multipartPatterns ?? []) + [part] }
    }

    /// Adds a multipart matcher from a fluent builder (Java
    /// `withMultipartRequestBody(MultipartValuePatternBuilder)`).
    public func withMultipartRequestBody(_ builder: MultipartValuePatternBuilder) -> Self {
        withMultipartRequestBody(builder.build())
    }

    public func withHost(_ matcher: StringValuePattern) -> Self {
        mutating { $0.host = matcher }
    }

    public func withPort(_ port: Int) -> Self {
        mutating { $0.port = port }
    }

    public func withScheme(_ scheme: String) -> Self {
        mutating { $0.scheme = scheme }
    }

    public func withClientIp(_ matcher: StringValuePattern) -> Self {
        mutating { $0.clientIp = matcher }
    }

    /// Matches with a named server-side custom matcher extension
    /// (`andMatching(name, parameters)` in Java). The matcher must be registered
    /// on the WireMock server.
    public func andMatching(_ name: String, parameters: [String: JSONValue]? = nil) -> Self {
        mutating { $0.customMatcher = CustomMatcherDefinition(name: name, parameters: parameters) }
    }
}

public func getRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .get, url: url) }
public func postRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .post, url: url) }
public func putRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .put, url: url) }
public func patchRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .patch, url: url) }
public func deleteRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .delete, url: url) }
public func headRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .head, url: url) }
public func optionsRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .options, url: url) }
public func traceRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .trace, url: url) }
public func getOrHeadRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .getOrHead, url: url) }
public func anyRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .any, url: url) }

/// Verifies requests for an arbitrary method (mirrors Java `requestedFor(method, url)`).
public func requestedFor(_ method: HTTPMethod, _ url: UrlPattern) -> RequestPatternBuilder { .init(method: method, url: url) }

/// A count strategy satisfied only by zero matching requests (`never()` in
/// Java): `verify(never(), getRequestedFor(...))`.
public func never() -> CountMatchingStrategy { .exactly(0) }

/// How a verified request count is checked.
public enum CountMatchingStrategy: Sendable, CustomStringConvertible {
    case exactly(Int)
    case lessThan(Int)
    case lessThanOrExactly(Int)
    case moreThan(Int)
    case moreThanOrExactly(Int)

    func isSatisfied(by count: Int) -> Bool {
        switch self {
        case .exactly(let n): return count == n
        case .lessThan(let n): return count < n
        case .lessThanOrExactly(let n): return count <= n
        case .moreThan(let n): return count > n
        case .moreThanOrExactly(let n): return count >= n
        }
    }

    /// Whether `count` fails the strategy by being too *low* (so more matching
    /// requests would satisfy it). Used to decide whether near-miss diagnostics
    /// are worth fetching — they are meaningless for a "too many" failure, where
    /// the requests *did* match.
    func isShortfall(_ count: Int) -> Bool {
        switch self {
        case .exactly(let n): return count < n
        case .lessThan, .lessThanOrExactly: return false
        case .moreThan(let n): return count <= n
        case .moreThanOrExactly(let n): return count < n
        }
    }

    public var description: String {
        switch self {
        case .exactly(let n): return "exactly \(n)"
        case .lessThan(let n): return "less than \(n)"
        case .lessThanOrExactly(let n): return "less than or exactly \(n)"
        case .moreThan(let n): return "more than \(n)"
        case .moreThanOrExactly(let n): return "more than or exactly \(n)"
        }
    }
}

/// Thrown by `verify` when the actual request count doesn't satisfy the strategy.
///
/// When the failure is a shortfall (fewer matches than expected), `nearMisses`
/// carries the closest requests/stubs and their per-field diffs, and
/// `description` appends that diff report — mirroring Java's
/// `VerificationException`, which is the single most useful thing when a mock
/// expectation fails.
public struct VerificationError: Error, CustomStringConvertible, Sendable {
    public let expected: String
    public let actual: Int
    /// Closest near-misses for the verified pattern (empty when unavailable — a
    /// "too many" failure, a disabled journal, or a failed lookup).
    public let nearMisses: [NearMiss]

    public init(expected: String, actual: Int, nearMisses: [NearMiss] = []) {
        self.expected = expected
        self.actual = actual
        self.nearMisses = nearMisses
    }

    public var description: String {
        let base = "Expected \(expected) matching request(s) but found \(actual)"
        guard let report = Self.closestDiffReport(nearMisses) else { return base }
        return base + "\n\nClosest match:\n" + report
    }

    /// Renders a diagnostic block for the smallest-distance near miss. Prefers the
    /// server's per-field diff when present; otherwise summarises the closest
    /// actual request (WireMock 3.13.2's request-pattern near misses carry the
    /// request and a distance but leave `diffDescriptions` empty). Returns `nil`
    /// when there is nothing useful to show.
    private static func closestDiffReport(_ nearMisses: [NearMiss]) -> String? {
        guard let closest = nearMisses.min(by: {
            ($0.matchResult?.distance ?? .greatestFiniteMagnitude)
          < ($1.matchResult?.distance ?? .greatestFiniteMagnitude)
        }) else { return nil }

        if let diffs = closest.matchResult?.diffDescriptions, !diffs.isEmpty {
            return diffs.map { diff in
                if let message = diff.errorMessage, !message.isEmpty { return "  - " + message }
                return "  - expected \(diff.expected ?? "(absent)") but was \(diff.actual ?? "(absent)")"
            }.joined(separator: "\n")
        }

        if let request = closest.request {
            let method = request.method.map(String.init(describing:)) ?? "?"
            var line = "  closest request was: \(method) \(request.url ?? "?")"
            if let distance = closest.matchResult?.distance {
                let rounded = (distance * 100).rounded() / 100
                line += " (distance \(rounded))"
            }
            return line
        }
        return nil
    }
}
