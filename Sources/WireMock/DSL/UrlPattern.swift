import Foundation

/// Describes how the request URL is matched. Produced by the free functions
/// `urlEqualTo`, `urlMatching`, `urlPathEqualTo`, `urlPathMatching`,
/// `urlPathTemplate`, and `anyUrl`.
public struct UrlPattern: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case url, urlPattern, urlPath, urlPathPattern, urlPathTemplate, any
    }

    let kind: Kind
    let value: String?

    func apply(to request: inout RequestPattern) {
        switch kind {
        case .url: request.url = value
        case .urlPattern: request.urlPattern = value
        case .urlPath: request.urlPath = value
        case .urlPathPattern: request.urlPathPattern = value
        case .urlPathTemplate: request.urlPathTemplate = value
        case .any: break
        }
    }
}

extension UrlPattern: CustomStringConvertible {
    /// Readable `wireKey=value` (e.g. `urlPath=/things`), or `anyUrl`.
    public var description: String {
        let key: String
        switch kind {
        case .url: key = "url"
        case .urlPattern: key = "urlPattern"
        case .urlPath: key = "urlPath"
        case .urlPathPattern: key = "urlPathPattern"
        case .urlPathTemplate: key = "urlPathTemplate"
        case .any: return "anyUrl"
        }
        return "\(key)=\(value ?? "")"
    }
}

/// Match the full URL (path + query) exactly.
public func urlEqualTo(_ url: String) -> UrlPattern { .init(kind: .url, value: url) }
/// Match the full URL (path + query) by regex.
public func urlMatching(_ pattern: String) -> UrlPattern { .init(kind: .urlPattern, value: pattern) }
/// Match the path only, exactly (ignores query string).
public func urlPathEqualTo(_ path: String) -> UrlPattern { .init(kind: .urlPath, value: path) }
/// Match the path only, by regex.
public func urlPathMatching(_ pattern: String) -> UrlPattern { .init(kind: .urlPathPattern, value: pattern) }
/// Match the path against an RFC 6570 template (e.g. `/things/{id}`).
public func urlPathTemplate(_ template: String) -> UrlPattern { .init(kind: .urlPathTemplate, value: template) }
/// Match any URL.
public let anyUrl = UrlPattern(kind: .any, value: nil)

// MARK: - HTTP method entry points (mirror WireMock's Java DSL)

/// Start a stub for a GET request to the given URL.
public func get(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .get, url: url) }
/// Start a stub for a POST request to the given URL.
public func post(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .post, url: url) }
/// Start a stub for a PUT request to the given URL.
public func put(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .put, url: url) }
/// Start a stub for a PATCH request to the given URL.
public func patch(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .patch, url: url) }
/// Start a stub for a DELETE request to the given URL.
public func delete(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .delete, url: url) }
/// Start a stub for a HEAD request to the given URL.
public func head(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .head, url: url) }
/// Start a stub for an OPTIONS request to the given URL.
public func options(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .options, url: url) }
/// Start a stub for a TRACE request to the given URL.
public func trace(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .trace, url: url) }
/// Start a stub matching requests of any HTTP method.
public func any(_ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: .any, url: url) }
/// Start a stub for an arbitrary HTTP method.
public func request(_ method: HTTPMethod, _ url: UrlPattern) -> MappingBuilder { MappingBuilder(method: method, url: url) }
