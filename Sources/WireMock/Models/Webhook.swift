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
    public var headers: [String: HeaderValue]
    public var body: String?
    public var base64Body: String?
    public var jsonBody: JSONValue?
    public var delay: Delay?
    /// Transformers applied to the outbound webhook request, e.g.
    /// `["response-template"]` to template the url/headers/body against the
    /// original request (Java `WebhookDefinition.withTransformers`).
    public var transformers: [String]?
    /// Free-form parameters passed to the webhook (Java `withExtraParameter`).
    /// Accepted and persisted by the server and consumed by custom/server-side
    /// webhook transformers; the built-in `response-template` transformer on
    /// WireMock 3.13.2 does not expose them as template variables.
    public var extraParameters: [String: JSONValue]?

    /// Delay applied before the webhook fires. `uniform`/`lognormal` match the
    /// response delay-distribution shape; `fixed` is a constant-delay form
    /// specific to webhooks (the response side uses `fixedDelayMilliseconds`).
    public enum Delay: Sendable, Hashable {
        case fixed(milliseconds: Int)
        case uniform(lower: Int, upper: Int)
        /// `maxValue` optionally caps the sampled delay (milliseconds), matching
        /// the `LogNormal` distribution's optional `maxValue` field.
        case lognormal(median: Double, sigma: Double, maxValue: Double? = nil)

        var asJSON: JSONValue {
            switch self {
            case let .fixed(milliseconds):
                return ["type": "fixed", "milliseconds": .int(milliseconds)]
            case let .uniform(lower, upper):
                return ["type": "uniform", "lower": .int(lower), "upper": .int(upper)]
            case let .lognormal(median, sigma, maxValue):
                var fields: [String: JSONValue] = ["type": "lognormal", "median": .double(median), "sigma": .double(sigma)]
                if let maxValue { fields["maxValue"] = .double(maxValue) }
                return .object(fields)
            }
        }
    }

    public init(
        method: HTTPMethod,
        url: String,
        headers: [String: HeaderValue] = [:],
        body: String? = nil,
        base64Body: String? = nil,
        jsonBody: JSONValue? = nil,
        delay: Delay? = nil,
        transformers: [String]? = nil,
        extraParameters: [String: JSONValue]? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.base64Body = base64Body
        self.jsonBody = jsonBody
        self.delay = delay
        self.transformers = transformers
        self.extraParameters = extraParameters
    }

    /// Renders this webhook into a `serveEventListeners` entry.
    public func asServeEventListener() -> ServeEventListenerDefinition {
        var parameters: [String: JSONValue] = [
            "method": .string(method.rawValue),
            "url": .string(url)
        ]
        if !headers.isEmpty {
            parameters["headers"] = .object(headers.mapValues { value in
                switch value {
                case .single(let string): return .string(string)
                case .multiple(let strings): return .array(strings.map { .string($0) })
                }
            })
        }
        if let body {
            parameters["body"] = .string(body)
        } else if let jsonBody,
                  let data = try? JSONEncoder().encode(jsonBody),
                  let string = String(data: data, encoding: .utf8) {
            // WireMock's webhook listener has no `jsonBody` parameter (it is
            // silently ignored), so serialise it into `body` to actually send it.
            parameters["body"] = .string(string)
        }
        if let base64Body { parameters["base64Body"] = .string(base64Body) }
        if let delay { parameters["delay"] = delay.asJSON }
        if let transformers, !transformers.isEmpty {
            parameters["transformers"] = .array(transformers.map { .string($0) })
        }
        if let extraParameters, !extraParameters.isEmpty {
            parameters["extraParameters"] = .object(extraParameters)
        }
        return ServeEventListenerDefinition(name: "webhook", parameters: parameters)
    }
}
