import Foundation

// MARK: - Request expectations (BDD-style, additive layer)
//
// A thin, purely additive layer on top of the existing verification API
// (`findAll` / `count` / `findNearMisses`). It reads outgoing requests captured
// in the server's journal and lets you assert on them fluently:
//
// ```swift
// try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
//     .toHaveBeenSent(.once)
//     .toHaveBearerToken("eyJ...")
//     .toHaveJsonPath("$.items[0].sku", equalTo("ABC"))
//
// let id = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
//     .toHaveBeenSent(.once)
//     .extract().jsonPath("$.id")
// ```
//
// The `to*` field checks refine the request pattern and re-ask the server, so
// matching stays server-side (identical to Java WireMock). `single()/first()/
// last()/extract()` inspect the captured request client-side — the only way to
// pull a value back out for correlation.
//
// Nothing here touches the existing `verify(...)` / `VerificationError` API.

extension WireMock {
    /// Starts a fluent expectation over the requests matching `builder`.
    ///
    /// Lazy: no server call happens here. Each `to*` check and each terminal
    /// (`single`/`first`/`last`/`all`/`extract`) performs its own query, so the
    /// result reflects the whole chain of refinements.
    public func expect(_ builder: RequestPatternBuilder) -> RequestExpectation {
        RequestExpectation(wireMock: self, builder: builder)
    }
}

/// How many matching requests a `toHaveBeenSent` expectation allows.
public enum CountSpec: Sendable, CustomStringConvertible {
    /// Exactly one.
    case once
    /// Exactly zero.
    case never
    /// Exactly `n`.
    case times(Int)
    /// `n` or more.
    case atLeast(Int)
    /// `n` or fewer.
    case atMost(Int)
    /// Strictly more than `n`.
    case moreThan(Int)
    /// Strictly fewer than `n`.
    case lessThan(Int)
    /// Anywhere in the inclusive range.
    case between(ClosedRange<Int>)

    /// Whether `count` satisfies the spec.
    public func isSatisfied(by count: Int) -> Bool {
        switch self {
        case .once: return count == 1
        case .never: return count == 0
        case .times(let n): return count == n
        case .atLeast(let n): return count >= n
        case .atMost(let n): return count <= n
        case .moreThan(let n): return count > n
        case .lessThan(let n): return count < n
        case .between(let r): return r.contains(count)
        }
    }

    /// Whether `count` fails by being too *low* (more matching requests would
    /// help). Only then are near-miss diagnostics worth fetching — for a
    /// "too many" failure the requests already matched.
    func isShortfall(_ count: Int) -> Bool {
        switch self {
        case .once: return count < 1
        case .never: return false
        case .times(let n): return count < n
        case .atLeast(let n): return count < n
        case .atMost: return false
        case .moreThan(let n): return count <= n
        case .lessThan: return false
        case .between(let r): return count < r.lowerBound
        }
    }

    public var description: String {
        switch self {
        case .once: return "exactly 1"
        case .never: return "exactly 0 (never)"
        case .times(let n): return "exactly \(n)"
        case .atLeast(let n): return "at least \(n)"
        case .atMost(let n): return "at most \(n)"
        case .moreThan(let n): return "more than \(n)"
        case .lessThan(let n): return "fewer than \(n)"
        case .between(let r): return "between \(r.lowerBound) and \(r.upperBound)"
        }
    }
}

/// Thrown by the `expect(...)` layer when an expectation is not met.
///
/// Distinct from `VerificationError` (which the older `verify(...)` API throws)
/// so the two layers stay independent. On a shortfall the message carries a
/// near-miss diff; on a "too many" failure it dumps every matching request.
public struct RequestExpectationError: Error, CustomStringConvertible, Sendable {
    /// The human-readable failure message (near-miss diff, request dump, or the
    /// reason a terminal/extractor could not produce a value). Also surfaced via
    /// `description`.
    public let message: String
    /// Wraps a ready-rendered failure message.
    public init(message: String) { self.message = message }
    public var description: String { message }
}
