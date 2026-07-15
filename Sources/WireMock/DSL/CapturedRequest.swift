import Foundation

/// A single request captured from the server's journal, with typed accessors so
/// you don't have to unpack the raw `HeaderValue`/`JSONValue` shapes by hand.
///
/// Obtained from ``RequestExpectation/single()``, `first()`, `last()`, or `all()`.
public struct CapturedRequest: Sendable {
    /// The underlying journal entry.
    public let logged: LoggedRequest

    public init(logged: LoggedRequest) { self.logged = logged }

    // MARK: - Typed accessors

    public var method: HTTPMethod? { logged.method }
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
        guard let raw = logged.url,
              let query = raw.split(separator: "?", maxSplits: 1).dropFirst().first else { return [] }
        var components = URLComponents()
        // Treat '+' as a space (the application/x-www-form-urlencoded convention
        // servers use when decoding query strings). A literal plus arrives as
        // %2B and survives; URLComponents only percent-decodes and would leave a
        // bare '+' untouched.
        components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20")
        return components.queryItems ?? []
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
                guard let array = value.arrayValue, array.indices.contains(index) else {
                    throw RequestExpectationError(message: "JSONPath '\(path)': index \(index) out of range")
                }
                value = array[index]
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
                let isQuoted = (spaceless.hasPrefix("'") && spaceless.hasSuffix("'"))
                    || (spaceless.hasPrefix("\"") && spaceless.hasSuffix("\""))
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
        guard !name.isEmpty else {
            throw RequestExpectationError(message: "Invalid JSONPath '\(path)': empty segment")
        }
        return name
    }
}
