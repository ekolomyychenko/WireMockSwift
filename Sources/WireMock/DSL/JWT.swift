import Foundation

/// A decoded JSON Web Token — its header and payload as `JSONValue`, for
/// asserting on JWTs a client sends to an identity provider (`client_assertion`
/// for private_key_jwt client auth, `id_token_hint` on logout, a DPoP proof
/// header, or a JWT-shaped bearer token).
///
/// **The signature is not verified** — this only base64url-decodes the segments
/// and parses their JSON, so you can inspect claims. That is a deliberate,
/// documented limitation (like the JSONPath subset in ``RequestExtractor``):
/// verifying a signature would need the issuer's keys and crypto, which test
/// assertions on *outgoing* requests don't typically do. Decode, then assert on
/// the claims you care about (`iss`, `aud`, `sub`, `exp`, `scope`, …).
///
/// ```swift
/// let jwt = try wireMock.expect(postRequestedFor(urlPathEqualTo("/token")))
///     .single().extract().jwt(formParam: "client_assertion")
/// XCTAssertEqual(jwt.claim("iss")?.stringValue, "my-client-id")
/// ```
public struct JWT: Sendable {
    /// The decoded JOSE header (e.g. `{"alg":"RS256","typ":"JWT","kid":"…"}`).
    public let header: JSONValue
    /// The decoded claims set (e.g. `{"iss":"…","aud":"…","exp":123}`).
    public let payload: JSONValue
    /// The raw (still base64url-encoded) signature segment, or "" for an unsigned
    /// (two-segment) token.
    public let rawSignature: String

    /// Decodes a compact-serialization JWT (`header.payload` or
    /// `header.payload.signature`). Throws `RequestExpectationError` if the shape
    /// or the base64url/JSON of either segment is invalid.
    public init(decoding token: String) throws {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 2 || segments.count == 3 else {
            throw RequestExpectationError(
                message: "Not a JWT: expected 2 or 3 '.'-separated base64url segments, got \(segments.count)"
            )
        }
        self.header = try Self.decodeSegment(segments[0], label: "header")
        self.payload = try Self.decodeSegment(segments[1], label: "payload")
        self.rawSignature = segments.count == 3 ? segments[2] : ""
    }

    /// The value of a top-level claim in the payload, or `nil` if the payload
    /// isn't an object or the claim is absent.
    public func claim(_ name: String) -> JSONValue? {
        payload.objectValue?[name]
    }

    private static func decodeSegment(_ segment: String, label: String) throws -> JSONValue {
        guard let data = base64URLDecode(segment) else {
            throw RequestExpectationError(message: "JWT \(label) is not valid base64url")
        }
        guard let text = String(data: data, encoding: .utf8), let json = JSONValue(parsing: text) else {
            throw RequestExpectationError(message: "JWT \(label) is not valid JSON")
        }
        return json
    }

    /// Decodes base64url (RFC 7515 §2): `-`/`_` for `+`/`/`, padding stripped.
    static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Pulling a JWT out of a captured request

extension RequestExtractor {
    /// Decodes the JWT carried by the `Authorization: Bearer <jwt>` header.
    /// Throws if the header is missing, isn't a `Bearer` scheme, or isn't a JWT.
    public func bearerJWT() throws -> JWT {
        guard let value = header("Authorization") else {
            throw RequestExpectationError(message: "No Authorization header to read a bearer JWT from")
        }
        // RFC 6750 §2.1 / RFC 7235: the auth scheme is case-insensitive, so accept
        // "Bearer", "bearer", "BEARER", … before dropping it.
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw RequestExpectationError(message: "Authorization header is not a Bearer token: \(value)")
        }
        return try JWT(decoding: String(parts[1]))
    }

    /// Decodes the JWT carried by the named header (e.g. a `DPoP` proof).
    public func jwt(header name: String) throws -> JWT {
        guard let value = header(name) else {
            throw RequestExpectationError(message: "No '\(name)' header to read a JWT from")
        }
        return try JWT(decoding: value)
    }

    /// Decodes the JWT carried by a form-body parameter (e.g. `client_assertion`).
    public func jwt(formParam name: String) throws -> JWT {
        guard let value = formParam(name) else {
            throw RequestExpectationError(message: "No '\(name)' form parameter to read a JWT from")
        }
        return try JWT(decoding: value)
    }

    /// Decodes the JWT carried by a query parameter (e.g. `id_token_hint`).
    public func jwt(queryParam name: String) throws -> JWT {
        guard let value = queryParam(name) else {
            throw RequestExpectationError(message: "No '\(name)' query parameter to read a JWT from")
        }
        return try JWT(decoding: value)
    }
}
