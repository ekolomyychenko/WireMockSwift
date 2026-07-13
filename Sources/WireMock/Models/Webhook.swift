import Foundation

/// A serve-event listener attached to a stub (`serveEventListeners` entry),
/// e.g. the built-in `webhook` listener. Parameters are free-form JSON so any
/// current or future listener can be configured.
public struct ServeEventListenerDefinition: Codable, Sendable, Hashable {
    public var name: String
    public var parameters: [String: JSONValue]?
    /// Which lifecycle events to fire on (e.g. `["AFTER_COMPLETE"]`). Optional.
    public var requestPhases: [String]?

    public init(name: String, parameters: [String: JSONValue]? = nil, requestPhases: [String]? = nil) {
        self.name = name
        self.parameters = parameters
        self.requestPhases = requestPhases
    }
}

/// Typed builder for the built-in WireMock `webhook` listener: fires an
/// outbound HTTP request when the stub is matched.
public struct WebhookDefinition: Sendable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [String: String]
    public var body: String?
    public var base64Body: String?
    public var jsonBody: JSONValue?
    public var delay: Delay?

    /// Delay applied before the webhook fires. Mirrors the response
    /// `DelayDistribution` shape, with a `fixed` case for a constant delay.
    public enum Delay: Sendable, Hashable {
        case fixed(milliseconds: Int)
        case uniform(lower: Int, upper: Int)
        case lognormal(median: Double, sigma: Double)

        var asJSON: JSONValue {
            switch self {
            case let .fixed(milliseconds):
                return ["type": "fixed", "milliseconds": .int(milliseconds)]
            case let .uniform(lower, upper):
                return ["type": "uniform", "lower": .int(lower), "upper": .int(upper)]
            case let .lognormal(median, sigma):
                return ["type": "lognormal", "median": .double(median), "sigma": .double(sigma)]
            }
        }
    }

    public init(
        method: HTTPMethod,
        url: String,
        headers: [String: String] = [:],
        body: String? = nil,
        base64Body: String? = nil,
        jsonBody: JSONValue? = nil,
        delay: Delay? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.base64Body = base64Body
        self.jsonBody = jsonBody
        self.delay = delay
    }

    /// Renders this webhook into a `serveEventListeners` entry.
    public func asServeEventListener() -> ServeEventListenerDefinition {
        var parameters: [String: JSONValue] = [
            "method": .string(method.rawValue),
            "url": .string(url),
        ]
        if !headers.isEmpty {
            parameters["headers"] = .object(headers.mapValues { .string($0) })
        }
        if let body { parameters["body"] = .string(body) }
        if let base64Body { parameters["base64Body"] = .string(base64Body) }
        if let jsonBody { parameters["jsonBody"] = jsonBody }
        if let delay { parameters["delay"] = delay.asJSON }
        return ServeEventListenerDefinition(name: "webhook", parameters: parameters)
    }
}
