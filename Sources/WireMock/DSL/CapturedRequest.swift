import Foundation

/// A single request captured from the server's journal, with typed accessors so
/// you don't have to unpack the raw `HeaderValue`/`JSONValue` shapes by hand.
///
/// Obtained from ``RequestExpectation/single()``, `first()`, `last()`, or `all()`.
public struct CapturedRequest: Sendable {
    /// The underlying journal entry.
    public let logged: LoggedRequest

    /// Wraps a journal entry for typed access.
    public init(logged: LoggedRequest) { self.logged = logged }

    // MARK: - Typed accessors

    /// The request method, or `nil` if the journal entry omitted it.
    public var method: HTTPMethod? { logged.method }
    /// The request URL (path and query), or `nil` if absent.
    public var url: String? { logged.url }

    /// The raw request body as text, if any.
    public var bodyString: String? { logged.body }

    /// The request body parsed as JSON, or `nil` if it isn't valid JSON.
    public var bodyJSON: JSONValue? { logged.body.flatMap { JSONValue(parsing: $0) } }

    /// All values for a header (case-insensitive name). Empty if absent.
    public func headers(_ name: String) -> [String] {
        guard let headers = logged.headers else { return [] }
        for (key, value) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
            switch value {
            case .single(let single): return [single]
            case .multiple(let multiple): return multiple
            }
        }
        return []
    }

    /// The first value for a header (case-insensitive name), or `nil`.
    public func header(_ name: String) -> String? { headers(name).first }

    /// The value of a cookie, or `nil` if absent.
    ///
    /// Cookie names are matched **case-sensitively** (RFC 6265 cookie names are
    /// case-sensitive), unlike `header(_:)` where names are case-insensitive.
    public func cookie(_ name: String) -> String? {
        guard let cookies = logged.cookies else { return nil }
        for (key, value) in cookies where key == name {
            switch value {
            case .single(let single): return single
            case .multiple(let multiple): return multiple.first
            }
        }
        return nil
    }

    /// All values for a query parameter (a key can repeat). A valueless param
    /// (`?flag`) is reported as one empty string, consistent with
    /// `toHaveExactlyQueryParams`.
    public func queryParam(_ name: String) -> [String] {
        queryItems().filter { $0.name == name }.map { $0.value ?? "" }
    }

    /// The query items parsed from the logged URL. Internal — `toHaveExactlyQueryParams`
    /// and `queryParam(_:)` build on it.
    func queryItems() -> [URLQueryItem] {
        // `omittingEmptySubsequences: false` keeps an empty path segment so a
        // query-only URL ("/?a=1", or even a path-less "?a=1") still lands the
        // query at index 1 rather than shifting `dropFirst()` onto it.
        guard let raw = logged.url,
              let query = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first
        else { return [] }
        // A fragment ("#…") is not part of the query (RFC 3986 §3.5); strip it so a
        // stray '#' can't leak into the last value or fabricate phantom params.
        let withoutFragment = query.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return Self.decodeURLEncoded(String(withoutFragment))
    }

    /// All values for an `application/x-www-form-urlencoded` body parameter (a key
    /// can repeat). Empty if the body is missing or empty. A valueless param
    /// (`flag&x=1`) is reported as one empty string, mirroring `queryParam(_:)`.
    ///
    /// The body is decoded as-is — this does not check `Content-Type`, so a
    /// non-form body just yields no matches. The token endpoint of an OAuth/OIDC
    /// provider posts form-encoded, so this is how you pull `code_verifier`,
    /// `grant_type`, `redirect_uri`, etc. back out for correlation.
    public func formParams(_ name: String) -> [String] {
        formItems().filter { $0.name == name }.map { $0.value ?? "" }
    }

    /// The first value for an `application/x-www-form-urlencoded` body parameter,
    /// or `nil` if absent.
    public func formParam(_ name: String) -> String? { formParams(name).first }

    /// The form items parsed from the logged body. Internal — `formParams(_:)`
    /// builds on it.
    func formItems() -> [URLQueryItem] {
        guard let body = logged.body, !body.isEmpty else { return [] }
        return Self.decodeURLEncoded(body)
    }

    /// Decodes an `application/x-www-form-urlencoded` string (a URL query string
    /// or a form-encoded body) into query items.
    ///
    /// Treats '+' as a space — the form-urlencoded convention servers use when
    /// decoding. A literal plus arrives as %2B and survives.
    ///
    /// Parses by hand rather than via `URLComponents.percentEncodedQuery`, whose
    /// setter **traps the whole process** (`Fatal error: … invalid characters`)
    /// on a stray `%` or `#` — shapes that arrive routinely (an unescaped `%` in
    /// a value, a `#` in a non-form body value, or any non-form body the accessors
    /// are documented to tolerate). A malformed percent-escape is left verbatim
    /// here instead of crashing.
    static func decodeURLEncoded(_ raw: String) -> [URLQueryItem] {
        raw.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = formDecode(String(halves[0]))
            // A valueless param (`flag`) has no '=' and reports a nil value, which
            // the accessors surface as "" — matching WireMock/URLComponents.
            let value = halves.count > 1 ? formDecode(String(halves[1])) : nil
            return URLQueryItem(name: name, value: value)
        }
    }

    /// Percent-decodes one form-urlencoded component, treating '+' as a space.
    /// A malformed escape (e.g. `50%`) is returned unchanged rather than trapping.
    private static func formDecode(_ component: String) -> String {
        let spaced = component.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// A view for pulling values out of this request (for correlation).
    public func extract() -> RequestExtractor { RequestExtractor(request: self) }
}

/// Pulls values out of a captured request — the client-side counterpart to
/// RestAssured's `.extract()`. Use it to correlate requests (e.g. reuse an id
/// generated in one request when asserting the next).
public struct RequestExtractor: Sendable {
    let request: CapturedRequest

    /// The first value of a header (case-insensitive), or `nil`.
    public func header(_ name: String) -> String? { request.header(name) }

    /// The first value of a query parameter, or `nil`.
    public func queryParam(_ name: String) -> String? { request.queryParam(name).first }

    /// The first value of an `application/x-www-form-urlencoded` body parameter,
    /// or `nil`. Use it to correlate the OAuth/OIDC token endpoint — e.g. pull
    /// `code_verifier` back out to check it against the `code_challenge` sent to
    /// `/authorize`.
    public func formParam(_ name: String) -> String? { request.formParam(name) }

    /// The raw request body as text.
    public func body() -> String? { request.bodyString }

    /// The value at a JSONPath in the request body.
    ///
    /// Supports a documented subset — object keys and array indices
    /// (`$.id`, `$.items[0].sku`, `$['a'].b`) — enough for extraction and
    /// correlation. For anything richer, use ``CapturedRequest/bodyJSON``.
    public func jsonPath(_ path: String) throws -> JSONValue {
        guard let json = request.bodyJSON else {
            throw RequestExpectationError(message: "Cannot read JSONPath '\(path)': request body is not valid JSON")
        }
        return try JSONPathLite.evaluate(path, on: json)
    }
}

/// A minimal JSONPath evaluator: `$`, `.key`, `[index]`, and `['key']`.
/// Deliberately not full Jayway — just enough to pull a value out for
/// correlation. Navigation failures throw `RequestExpectationError`.
enum JSONPathLite {
    private enum Token {
        case key(String)
        case index(Int)
    }

    static func evaluate(_ path: String, on root: JSONValue) throws -> JSONValue {
        var value = root
        for token in try tokens(path) {
            switch token {
            case .key(let key):
                guard let object = value.objectValue, let next = object[key] else {
                    throw RequestExpectationError(message: "JSONPath '\(path)': key '\(key)' not found")
                }
                value = next
            case .index(let index):
                guard let array = value.arrayValue else {
                    throw RequestExpectationError(message: "JSONPath '\(path)': index \(index) applied to a non-array")
                }
                // A negative index counts from the end (Jayway/RestAssured parity):
                // `$[-1]` is the last element.
                let resolved = index < 0 ? array.count + index : index
                guard array.indices.contains(resolved) else {
                    throw RequestExpectationError(message: "JSONPath '\(path)': index \(index) out of range")
                }
                value = array[resolved]
            }
        }
        return value
    }

    private static func tokens(_ path: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(path)
        var i = 0
        if i < chars.count, chars[i] == "$" { i += 1 }
        while i < chars.count {
            let char = chars[i]
            if char == "." {
                i += 1
                tokens.append(.key(try readName(chars, &i, path)))
            } else if char == "[" {
                i += 1
                var inner = ""
                while i < chars.count, chars[i] != "]" { inner.append(chars[i]); i += 1 }
                guard i < chars.count else {
                    throw RequestExpectationError(message: "Invalid JSONPath '\(path)': unterminated '['")
                }
                i += 1 // consume ']'
                let spaceless = inner.trimmingCharacters(in: .whitespaces)
                // Require ≥2 chars so a lone quote (`$[']`) isn't read as its own
                // opening-and-closing quote around an empty key.
                let isQuoted = spaceless.count >= 2
                    && ((spaceless.hasPrefix("'") && spaceless.hasSuffix("'"))
                        || (spaceless.hasPrefix("\"") && spaceless.hasSuffix("\"")))
                if isQuoted {
                    // A quoted key is always a key, even if it looks numeric
                    // (`$['0']` is the object key "0", not array index 0).
                    tokens.append(.key(String(spaceless.dropFirst().dropLast())))
                } else if let index = Int(spaceless) {
                    tokens.append(.index(index))
                } else {
                    tokens.append(.key(spaceless))
                }
            } else {
                // Leading segment without a dot, e.g. "items" in "items[0]".
                tokens.append(.key(try readName(chars, &i, path)))
            }
        }
        return tokens
    }

    private static func readName(_ chars: [Character], _ i: inout Int, _ path: String) throws -> String {
        var name = ""
        while i < chars.count, chars[i] != ".", chars[i] != "[" { name.append(chars[i]); i += 1 }
        // Trim surrounding whitespace so `$.a ` reads the key "a", not "a " (the
        // bracket branch already trims; keep the dotted/bare branch consistent).
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw RequestExpectationError(message: "Invalid JSONPath '\(path)': empty segment")
        }
        return trimmed
    }
}
