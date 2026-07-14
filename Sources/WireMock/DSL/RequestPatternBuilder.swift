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

    public func withHeader(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.headers = ($0.headers ?? [:]).merging([name: matcher]) { _, new in new } }
    }

    public func withoutHeader(_ name: String) -> Self {
        withHeader(name, .absent)
    }

    public func withQueryParam(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.queryParameters = ($0.queryParameters ?? [:]).merging([name: matcher]) { _, new in new } }
    }

    /// Requires the query parameter to be absent.
    public func withoutQueryParam(_ name: String) -> Self {
        withQueryParam(name, .absent)
    }

    public func withCookie(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.cookies = ($0.cookies ?? [:]).merging([name: matcher]) { _, new in new } }
    }

    public func withRequestBody(_ matcher: StringValuePattern) -> Self {
        mutating { $0.bodyPatterns = ($0.bodyPatterns ?? []) + [matcher] }
    }

    public func withBasicAuth(username: String, password: String) -> Self {
        mutating { $0.basicAuthCredentials = BasicAuthCredentials(username: username, password: password) }
    }

    public func withPathParam(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.pathParameters = ($0.pathParameters ?? [:]).merging([name: matcher]) { _, new in new } }
    }

    public func withFormParam(_ name: String, _ matcher: StringValuePattern) -> Self {
        mutating { $0.formParameters = ($0.formParameters ?? [:]).merging([name: matcher]) { _, new in new } }
    }

    /// Requires the form parameter to be absent.
    public func withoutFormParam(_ name: String) -> Self {
        withFormParam(name, .absent)
    }

    public func withMultipartRequestBody(_ part: MultipartValuePattern) -> Self {
        mutating { $0.multipartPatterns = ($0.multipartPatterns ?? []) + [part] }
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
public func anyRequestedFor(_ url: UrlPattern) -> RequestPatternBuilder { .init(method: .any, url: url) }

/// Verifies requests for an arbitrary method (mirrors Java `requestedFor(method, url)`).
public func requestedFor(_ method: HTTPMethod, _ url: UrlPattern) -> RequestPatternBuilder { .init(method: method, url: url) }

/// How a verified request count is checked.
public enum CountMatchingStrategy: Sendable {
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

    var description: String {
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
public struct VerificationError: Error, CustomStringConvertible, Sendable {
    public let expected: String
    public let actual: Int

    public var description: String {
        "Expected \(expected) matching request(s) but found \(actual)"
    }
}
