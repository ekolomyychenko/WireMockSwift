import Foundation

/// Anything that can supply a `ResponseDefinition` to `willReturn(_:)` — both
/// `ResponseDefinitionBuilder` and its proxy variant conform.
public protocol ResponseDefinitionProviding: Sendable {
    var definition: ResponseDefinition { get }
}

/// Fluent builder for a `ResponseDefinition`. Mirrors WireMock's
/// `ResponseDefinitionBuilder` (`aResponse().withStatus(200).withBody(…)`).
///
/// Value-typed: each `with…` returns a modified copy, so builders are safe to
/// share and compose.
public struct ResponseDefinitionBuilder: Sendable {
    public private(set) var definition: ResponseDefinition

    public init() { self.definition = ResponseDefinition() }

    private func mutating(_ transform: (inout ResponseDefinition) -> Void) -> Self {
        var copy = self
        transform(&copy.definition)
        return copy
    }

    public func withStatus(_ status: Int) -> Self {
        mutating { $0.status = status }
    }

    public func withStatusMessage(_ message: String) -> Self {
        mutating { $0.statusMessage = message }
    }

    public func withBody(_ body: String) -> Self {
        mutating { $0.body = body }
    }

    public func withJsonBody(_ json: JSONValue) -> Self {
        mutating { $0.jsonBody = json }
    }

    public func withBase64Body(_ base64: String) -> Self {
        mutating { $0.base64Body = base64 }
    }

    public func withBodyFile(_ fileName: String) -> Self {
        mutating { $0.bodyFileName = fileName }
    }

    public func withHeader(_ name: String, _ value: HeaderValue) -> Self {
        mutating {
            var headers = $0.headers ?? [:]
            headers[name] = value
            $0.headers = headers
        }
    }

    /// Replaces the entire response header set (Java `withHeaders(HttpHeaders)`
    /// reassigns the list, discarding anything set by a prior `withHeader`). Use
    /// `withHeader` to add to the set incrementally.
    public func withHeaders(_ headers: [String: HeaderValue]) -> Self {
        mutating { $0.headers = headers }
    }

    public func withFixedDelay(_ milliseconds: Int) -> Self {
        mutating { $0.fixedDelayMilliseconds = milliseconds }
    }

    public func withLogNormalRandomDelay(median: Double, sigma: Double, maxValue: Double? = nil) -> Self {
        mutating { $0.delayDistribution = .lognormal(median: median, sigma: sigma, maxValue: maxValue) }
    }

    public func withUniformRandomDelay(lower: Int, upper: Int) -> Self {
        mutating { $0.delayDistribution = .uniform(lower: lower, upper: upper) }
    }

    public func withChunkedDribbleDelay(numberOfChunks: Int, totalDuration: Int) -> Self {
        mutating { $0.chunkedDribbleDelay = ChunkedDribbleDelay(numberOfChunks: numberOfChunks, totalDuration: totalDuration) }
    }

    public func withFault(_ fault: Fault) -> Self {
        mutating { $0.fault = fault }
    }

    public func withTransformers(_ transformers: String...) -> Self {
        mutating { $0.transformers = transformers }
    }

    /// Sets a single transformer plus one of its parameters (`withTransformer`
    /// in Java).
    public func withTransformer(_ name: String, _ parameterKey: String, _ parameterValue: JSONValue) -> Self {
        mutating {
            $0.transformers = [name]
            var params = $0.transformerParameters ?? [:]
            params[parameterKey] = parameterValue
            $0.transformerParameters = params
        }
    }

    public func withTransformerParameter(_ name: String, _ value: JSONValue) -> Self {
        mutating {
            var params = $0.transformerParameters ?? [:]
            params[name] = value
            $0.transformerParameters = params
        }
    }

    /// Merges several transformer parameters at once (`withTransformerParameters`
    /// in Java).
    public func withTransformerParameters(_ parameters: [String: JSONValue]) -> Self {
        mutating {
            var params = $0.transformerParameters ?? [:]
            params.merge(parameters) { _, new in new }
            $0.transformerParameters = params
        }
    }

    /// Proxies matching requests to another host. Configure the response
    /// (status/headers/body) *before* calling this; the returned
    /// `ProxyResponseDefinitionBuilder` then exposes the proxy-only tweaks
    /// (mirrors Java, where `proxiedFrom` returns a `ProxyResponseDefinitionBuilder`).
    public func proxiedFrom(_ proxyBaseUrl: String) -> ProxyResponseDefinitionBuilder {
        var definition = self.definition
        definition.proxyBaseUrl = proxyBaseUrl
        return ProxyResponseDefinitionBuilder(definition: definition)
    }

    /// Disables gzip on the response (WireMock does this via a
    /// `Content-Encoding: none` header, not a JSON field).
    public func withGzipDisabled() -> Self {
        withHeader("Content-Encoding", "none")
    }
}

/// The proxy-only extension of `ResponseDefinitionBuilder`, returned by
/// `proxiedFrom(_:)`. Mirrors Java's `ProxyResponseDefinitionBuilder`: the
/// proxy-request tweaks below are reachable *only* after `proxiedFrom`, so they
/// can't be called on a non-proxy response.
public struct ProxyResponseDefinitionBuilder: Sendable {
    public private(set) var definition: ResponseDefinition

    init(definition: ResponseDefinition) { self.definition = definition }

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
