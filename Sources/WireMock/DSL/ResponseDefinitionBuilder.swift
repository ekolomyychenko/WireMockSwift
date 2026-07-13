import Foundation

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

    public func withHeaders(_ headers: [String: HeaderValue]) -> Self {
        mutating { $0.headers = ($0.headers ?? [:]).merging(headers) { _, new in new } }
    }

    public func withFixedDelay(_ milliseconds: Int) -> Self {
        mutating { $0.fixedDelayMilliseconds = milliseconds }
    }

    public func withLogNormalRandomDelay(median: Double, sigma: Double) -> Self {
        mutating { $0.delayDistribution = .lognormal(median: median, sigma: sigma) }
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

    public func withTransformerParameter(_ name: String, _ value: JSONValue) -> Self {
        mutating {
            var params = $0.transformerParameters ?? [:]
            params[name] = value
            $0.transformerParameters = params
        }
    }

    public func proxiedFrom(_ proxyBaseUrl: String) -> Self {
        mutating { $0.proxyBaseUrl = proxyBaseUrl }
    }

    /// Adds a header injected into the proxied request (proxy responses only).
    public func withAdditionalProxyRequestHeader(_ name: String, _ value: String) -> Self {
        mutating {
            var headers = $0.additionalProxyRequestHeaders ?? [:]
            headers[name] = value
            $0.additionalProxyRequestHeaders = headers
        }
    }

    /// Removes a header from the proxied request (proxy responses only).
    public func withRemoveProxyRequestHeader(_ name: String) -> Self {
        mutating { $0.removeProxyRequestHeaders = ($0.removeProxyRequestHeaders ?? []) + [name] }
    }

    /// Strips a leading path prefix before proxying (proxy responses only).
    public func withProxyUrlPrefixToRemove(_ prefix: String) -> Self {
        mutating { $0.proxyUrlPrefixToRemove = prefix }
    }
}

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
public func seeOther(_ location: String) -> ResponseDefinitionBuilder {
    aResponse().withStatus(303).withHeader("Location", HeaderValue.single(location))
}

public func created() -> ResponseDefinitionBuilder { aResponse().withStatus(201) }
public func noContent() -> ResponseDefinitionBuilder { aResponse().withStatus(204) }
public func badRequest() -> ResponseDefinitionBuilder { aResponse().withStatus(400) }
public func unauthorized() -> ResponseDefinitionBuilder { aResponse().withStatus(401) }
public func forbidden() -> ResponseDefinitionBuilder { aResponse().withStatus(403) }
public func notFound() -> ResponseDefinitionBuilder { aResponse().withStatus(404) }
public func serverError() -> ResponseDefinitionBuilder { aResponse().withStatus(500) }
public func serviceUnavailable() -> ResponseDefinitionBuilder { aResponse().withStatus(503) }
