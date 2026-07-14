import Foundation

/// Basic-auth credentials matcher (`{ "username": …, "password": … }`).
public struct BasicAuthCredentials: Codable, Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Names a server-side custom request-matcher extension and its parameters
/// (`{ "name": …, "parameters": {…} }`). The named matcher must be registered
/// on the WireMock server.
public struct CustomMatcherDefinition: Codable, Sendable, Hashable {
    public var name: String
    public var parameters: [String: JSONValue]?

    public init(name: String, parameters: [String: JSONValue]? = nil) {
        self.name = name
        self.parameters = parameters
    }
}

/// The `request` half of a stub mapping — the criteria a request must satisfy.
///
/// Mirrors WireMock's `RequestPattern` JSON. Exactly one URL form is normally
/// set; unset fields are omitted from the encoded JSON.
public struct RequestPattern: Codable, Sendable, Hashable {
    public var method: HTTPMethod?
    public var url: String?
    public var urlPattern: String?
    public var urlPath: String?
    public var urlPathPattern: String?
    public var urlPathTemplate: String?
    public var headers: [String: StringValuePattern]?
    public var queryParameters: [String: StringValuePattern]?
    public var cookies: [String: StringValuePattern]?
    public var pathParameters: [String: StringValuePattern]?
    public var formParameters: [String: StringValuePattern]?
    public var basicAuthCredentials: BasicAuthCredentials?
    public var bodyPatterns: [StringValuePattern]?
    public var multipartPatterns: [MultipartValuePattern]?
    public var host: StringValuePattern?
    public var port: Int?
    public var scheme: String?
    public var clientIp: StringValuePattern?
    /// A named server-side custom matcher extension (`andMatching`).
    public var customMatcher: CustomMatcherDefinition?

    public init(
        method: HTTPMethod? = nil,
        url: String? = nil,
        urlPattern: String? = nil,
        urlPath: String? = nil,
        urlPathPattern: String? = nil,
        urlPathTemplate: String? = nil,
        headers: [String: StringValuePattern]? = nil,
        queryParameters: [String: StringValuePattern]? = nil,
        cookies: [String: StringValuePattern]? = nil,
        pathParameters: [String: StringValuePattern]? = nil,
        formParameters: [String: StringValuePattern]? = nil,
        basicAuthCredentials: BasicAuthCredentials? = nil,
        bodyPatterns: [StringValuePattern]? = nil,
        multipartPatterns: [MultipartValuePattern]? = nil,
        host: StringValuePattern? = nil,
        port: Int? = nil,
        scheme: String? = nil,
        clientIp: StringValuePattern? = nil,
        customMatcher: CustomMatcherDefinition? = nil
    ) {
        self.method = method
        self.url = url
        self.urlPattern = urlPattern
        self.urlPath = urlPath
        self.urlPathPattern = urlPathPattern
        self.urlPathTemplate = urlPathTemplate
        self.headers = headers
        self.queryParameters = queryParameters
        self.cookies = cookies
        self.pathParameters = pathParameters
        self.formParameters = formParameters
        self.basicAuthCredentials = basicAuthCredentials
        self.bodyPatterns = bodyPatterns
        self.multipartPatterns = multipartPatterns
        self.host = host
        self.port = port
        self.scheme = scheme
        self.clientIp = clientIp
        self.customMatcher = customMatcher
    }
}
