import Foundation

// MARK: - In-order verification (additive)
//
// A cross-pattern ordering check on top of the existing journal API (`findAll`).
// The base `verify(...)`/`expect(...)` layers assert on ONE pattern at a time and
// can't say "authorize happened before token happened before userinfo". This adds
// exactly that, while keeping request matching server-side — only the timeline
// comparison (by `loggedDate`) is done client-side.

extension WireMock {
    /// Verifies that at least one request matched each builder, and that a valid
    /// ordering exists: a match for `builders[i]` occurred no earlier than the
    /// match chosen for `builders[i-1]`. Ideal for OAuth/OIDC flows, e.g.
    /// `verifyInOrder([authorize, token, userinfo])`.
    ///
    /// Matching stays server-side (each builder is a normal journal query); only
    /// the ordering is judged here, using the journal's `loggedDate`. That
    /// timestamp has **millisecond** resolution, so two steps sent within the same
    /// millisecond are treated as concurrent (either order accepted) rather than
    /// failing — real flows separated by network round-trips are unaffected.
    ///
    /// A valid ordering is decided by exhaustive search over the per-step
    /// candidates (the step count is tiny), so overlapping step patterns and
    /// same-millisecond ties don't produce a false failure: the sequence passes
    /// whenever *any* assignment of distinct requests with non-decreasing
    /// timestamps exists. The one residual limitation is two byte-identical
    /// requests in the same millisecond — indistinguishable via the journal — so
    /// a duplicated step pattern over such requests may still under-count.
    ///
    /// Throws `SequenceVerificationError` naming the first step that has no
    /// in-order match, and dumping the sequence chosen so far.
    public func verifyInOrder(_ builders: [RequestPatternBuilder]) throws {
        guard !builders.isEmpty else { return }

        // Candidate requests per step, matched server-side, oldest first.
        let candidates = try builders.map { builder in
            try findAll(builder).sorted { ($0.loggedDate ?? .max) < ($1.loggedDate ?? .max) }
        }

        // A step that matched nothing at all is the clearest failure to report.
        if let step = candidates.firstIndex(where: \.isEmpty) {
            throw SequenceVerificationError(
                step: step,
                stepSummary: RequestExpectation.summary(builders[step]),
                hadAnyMatch: false,
                chosen: []
            )
        }

        // Pass if any valid ordering exists (exact, not greedy).
        if Self.orderingExists(candidates, step: 0, cursor: .min, used: []) { return }

        // None exists — reproduce a greedy walk purely to name the stuck step and
        // dump the sequence chosen so far for the diagnostic.
        var cursor: Int64 = .min
        var chosen: [LoggedRequest] = []
        for (step, matches) in candidates.enumerated() {
            guard let pick = matches.first(where: { ($0.loggedDate ?? .max) >= cursor && !chosen.contains($0) }) else {
                throw SequenceVerificationError(
                    step: step,
                    stepSummary: RequestExpectation.summary(builders[step]),
                    hadAnyMatch: true,
                    chosen: chosen
                )
            }
            cursor = pick.loggedDate ?? cursor
            chosen.append(pick)
        }
    }

    /// Depth-first search for a system of distinct requests — one per remaining
    /// step — with non-decreasing `loggedDate`. Returns true iff such an
    /// assignment exists. The step count is small, so the exponential worst case
    /// (only reachable with heavily overlapping patterns and tied timestamps) is
    /// not a concern in practice.
    static func orderingExists(
        _ candidates: [[LoggedRequest]],
        step: Int,
        cursor: Int64,
        used: [LoggedRequest]
    ) -> Bool {
        if step == candidates.count { return true }
        for request in candidates[step] {
            let time = request.loggedDate ?? .max
            guard time >= cursor, !used.contains(request) else { continue }
            if orderingExists(candidates, step: step + 1, cursor: time, used: used + [request]) {
                return true
            }
        }
        return false
    }
}

/// Thrown by ``WireMock/verifyInOrder(_:)`` when no valid ordering of matching
/// requests exists. Independent of `VerificationError`/`RequestExpectationError`,
/// consistent with the library's one-error-type-per-assertion-layer style.
public struct SequenceVerificationError: Error, CustomStringConvertible, Sendable {
    /// Zero-based index of the step that could not be placed in order.
    public let step: Int
    /// `"METHOD url"` summary of the failing step's pattern.
    public let stepSummary: String
    /// Whether the step matched any request at all (`false` = never sent;
    /// `true` = sent, but only before an already-placed later step).
    public let hadAnyMatch: Bool
    /// The requests chosen for the steps that were satisfied before this one.
    public let chosen: [LoggedRequest]

    public var description: String {
        let reason = hadAnyMatch
            ? "matched a request, but only before the previous step in the sequence"
            : "matched no request at all"
        var message = "Requests out of order: step #\(step + 1) (\(stepSummary)) \(reason)."
        if chosen.isEmpty {
            message += "\n  (no earlier step was satisfied)"
        } else {
            message += "\n  Ordered so far:"
            for (index, request) in chosen.enumerated() {
                message += "\n    #\(index + 1)  \(RequestExpectation.compactLine(request))"
            }
        }
        return message
    }
}
