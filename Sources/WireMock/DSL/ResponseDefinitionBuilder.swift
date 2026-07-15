import Foundation

/// Anything that can supply a `ResponseDefinition` to `willReturn(_:)` — both
/// `ResponseDefinitionBuilder` and its proxy variant conform. The
/// `init(definition:)` requirement lets the shared base `with…` methods
/// (defined in the extension below) rebuild the concrete builder type.
public protocol ResponseDefinitionProviding: Sendable {
    var definition: ResponseDefinition { get }
    init(definition: ResponseDefinition)
}

/// Fluent builder for a `ResponseDefinition`. Mirrors WireMock's
/// `ResponseDefinitionBuilder` (`aResponse().withStatus(200).withBody(…)`).
///
/// Value-typed: each `with…` returns a modified copy, so builders are safe to
/// share and compose.
public struct ResponseDefinitionBuilder: Sendable {
    public private(set) var definition: ResponseDefinition

    public init() { self.definition = ResponseDefinition() }
    public init(definition: ResponseDefinition) { self.definition = definition }

    /// Proxies matching requests to another host. The returned
    /// `ProxyResponseDefinitionBuilder` adds the proxy-only tweaks while keeping
    /// every base `with…` method (mirrors Java, where
    /// `ProxyResponseDefinitionBuilder extends ResponseDefinitionBuilder`), so
    /// you can configure the response before *or* after `proxiedFrom`.
    public func proxiedFrom(_ proxyBaseUrl: String) -> ProxyResponseDefinitionBuilder {
        var definition = self.definition
        definition.proxyBaseUrl = proxyBaseUrl
        return ProxyResponseDefinitionBuilder(definition: definition)
    }
}

// MARK: - Base fluent methods (shared by both builders, like Java inheritance)

/// The base `ResponseDefinitionBuilder` surface, provided to every
/// `ResponseDefinitionProviding` so `ProxyResponseDefinitionBuilder` exposes it
/// too — matching Java, where the proxy builder *extends* the response builder.
public extension ResponseDefinitionProviding {
    private func configured(_ transform: (inout ResponseDefinition) -> Void) -> Self {
        var definition = self.definition
        transform(&definition)
        return Self(definition: definition)
    }

    func withStatus(_ status: Int) -> Self { configured { $0.status = status } }
    func withStatusMessage(_ message: String) -> Self { configured { $0.statusMessage = message } }
    func withBody(_ body: String) -> Self { configured { $0.body = body } }
    func withJsonBody(_ json: JSONValue) -> Self { configured { $0.jsonBody = json } }
    func withBase64Body(_ base64: String) -> Self { configured { $0.base64Body = base64 } }
    func withBodyFile(_ fileName: String) -> Self { configured { $0.bodyFileName = fileName } }

    func withHeader(_ name: String, _ value: HeaderValue) -> Self {
        configured { var headers = $0.headers ?? [:]; headers[name] = value; $0.headers = headers }
    }

    /// Replaces the entire response header set (Java `withHeaders(HttpHeaders)`
    /// reassigns the list, discarding anything set by a prior `withHeader`). Use
    /// `withHeader` to add to the set incrementally.
    func withHeaders(_ headers: [String: HeaderValue]) -> Self { configured { $0.headers = headers } }

    func withFixedDelay(_ milliseconds: Int) -> Self { configured { $0.fixedDelayMilliseconds = milliseconds } }

    func withLogNormalRandomDelay(median: Double, sigma: Double, maxValue: Double? = nil) -> Self {
        configured { $0.delayDistribution = .lognormal(median: median, sigma: sigma, maxValue: maxValue) }
    }

    func withUniformRandomDelay(lower: Int, upper: Int) -> Self {
        configured { $0.delayDistribution = .uniform(lower: lower, upper: upper) }
    }

    func withChunkedDribbleDelay(numberOfChunks: Int, totalDuration: Int) -> Self {
        configured { $0.chunkedDribbleDelay = ChunkedDribbleDelay(numberOfChunks: numberOfChunks, totalDuration: totalDuration) }
    }

    func withFault(_ fault: Fault) -> Self { configured { $0.fault = fault } }

    func withTransformers(_ transformers: String...) -> Self { configured { $0.transformers = transformers } }

    /// Sets a single transformer plus one of its parameters (`withTransformer` in Java).
    func withTransformer(_ name: String, _ parameterKey: String, _ parameterValue: JSONValue) -> Self {
        configured {
            $0.transformers = [name]
            var params = $0.transformerParameters ?? [:]
            params[parameterKey] = parameterValue
            $0.transformerParameters = params
        }
    }

    func withTransformerParameter(_ name: String, _ value: JSONValue) -> Self {
        configured {
            var params = $0.transformerParameters ?? [:]
            params[name] = value
            $0.transformerParameters = params
        }
    }

    /// Merges several transformer parameters at once (`withTransformerParameters` in Java).
    func withTransformerParameters(_ parameters: [String: JSONValue]) -> Self {
        configured {
            var params = $0.transformerParameters ?? [:]
            params.merge(parameters) { _, new in new }
            $0.transformerParameters = params
        }
    }

    /// Disables gzip on the response (WireMock does this via a
    /// `Content-Encoding: none` header, not a JSON field).
    func withGzipDisabled() -> Self { withHeader("Content-Encoding", "none") }
}

/// The proxy-only extension of `ResponseDefinitionBuilder`, returned by
/// `proxiedFrom(_:)`. Mirrors Java's `ProxyResponseDefinitionBuilder`: the
/// proxy-request tweaks below are reachable *only* after `proxiedFrom`, so they
/// can't be called on a non-proxy response.
public struct ProxyResponseDefinitionBuilder: Sendable {
    public private(set) var definition: ResponseDefinition

    public init(definition: ResponseDefinition) { self.definition = definition }

    private func mutating(_ transform: (inout ResponseDefinition) -> Void) -> Self {
        var copy = self
        transform(&copy.definition)
        return copy
    }

    /// Adds a header injected into the proxied request
    /// (Java: `withAdditionalRequestHeader`).
    public func withAdditionalRequestHeader(_ name: String, _ value: HeaderValue) -> Self {
        mutating {
            var headers = $0.additionalProxyRequestHeaders ?? [:]
            headers[name] = value
            $0.additionalProxyRequestHeaders = headers
        }
    }

    /// Removes a header from the proxied request (Java: `withRemoveRequestHeader`).
    /// The name is lower-cased to match Java, which normalises it with
    /// `key.toLowerCase()` before adding it to the list.
    public func withRemoveRequestHeader(_ name: String) -> Self {
        mutating { $0.removeProxyRequestHeaders = ($0.removeProxyRequestHeaders ?? []) + [name.lowercased()] }
    }

    /// Strips a leading path prefix before proxying.
    public func withProxyUrlPrefixToRemove(_ prefix: String) -> Self {
        mutating { $0.proxyUrlPrefixToRemove = prefix }
    }
}

extension ResponseDefinitionBuilder: ResponseDefinitionProviding {}
extension ProxyResponseDefinitionBuilder: ResponseDefinitionProviding {}

// MARK: - Entry points

/// An empty response builder (defaults to HTTP 200 on the server if no status set).
public func aResponse() -> ResponseDefinitionBuilder { ResponseDefinitionBuilder() }

public func ok() -> ResponseDefinitionBuilder { aResponse().withStatus(200) }

public func ok(_ body: String) -> ResponseDefinitionBuilder { aResponse().withStatus(200).withBody(body) }

public func okForJson(_ json: JSONValue) -> ResponseDefinitionBuilder {
    aResponse().withStatus(200)
        .withHeader("Content-Type", "application/json")
        .withJsonBody(json)
}

/// 200 with an empty JSON object body (`okForEmptyJson()` in Java).
public func okForEmptyJson() -> ResponseDefinitionBuilder {
    okForJson([:])
}

public func okForContentType(_ contentType: String, _ body: String) -> ResponseDefinitionBuilder {
    aResponse().withStatus(200).withHeader("Content-Type", HeaderValue.single(contentType)).withBody(body)
}

/// A response with the given status code and nothing else.
public func status(_ code: Int) -> ResponseDefinitionBuilder { aResponse().withStatus(code) }

/// A JSON response with the given body and status (defaults to 200).
public func jsonResponse(_ json: JSONValue, status: Int = 200) -> ResponseDefinitionBuilder {
    aResponse().withStatus(status).withHeader("Content-Type", "application/json").withJsonBody(json)
}

/// 302 redirect to `location`.
public func temporaryRedirect(to location: String) -> ResponseDefinitionBuilder {
    aResponse().withStatus(302).withHeader("Location", HeaderValue.single(location))
}
/// 301 redirect to `location`.
public func permanentRedirect(to location: String) -> ResponseDefinitionBuilder {
    aResponse().withStatus(301).withHeader("Location", HeaderValue.single(location))
}
/// 303 redirect to `location`.
public func seeOther(to location: String) -> ResponseDefinitionBuilder {
    aResponse().withStatus(303).withHeader("Location", HeaderValue.single(location))
}

public func created() -> ResponseDefinitionBuilder { aResponse().withStatus(201) }
public func noContent() -> ResponseDefinitionBuilder { aResponse().withStatus(204) }
public func badRequest() -> ResponseDefinitionBuilder { aResponse().withStatus(400) }
/// 422 Unprocessable Entity (`badRequestEntity()` in Java).
public func badRequestEntity() -> ResponseDefinitionBuilder { aResponse().withStatus(422) }
public func unauthorized() -> ResponseDefinitionBuilder { aResponse().withStatus(401) }
public func forbidden() -> ResponseDefinitionBuilder { aResponse().withStatus(403) }
public func notFound() -> ResponseDefinitionBuilder { aResponse().withStatus(404) }
public func serverError() -> ResponseDefinitionBuilder { aResponse().withStatus(500) }
public func serviceUnavailable() -> ResponseDefinitionBuilder { aResponse().withStatus(503) }
