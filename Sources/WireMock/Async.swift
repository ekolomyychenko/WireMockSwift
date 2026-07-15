import Foundation

public extension WireMock {
    /// Runs a synchronous client call from an `async` context.
    ///
    /// The client is **synchronous by design** (like Java WireMock) — from a
    /// normal (sync) test body just call `wireMock.stubFor(...)` directly. Use
    /// this only when you must reach the client from `async` code: it offloads
    /// the blocking call to a background queue and awaits it, so it never blocks
    /// a Swift-concurrency (cooperative) thread.
    ///
    /// - Note: each in-flight call parks a background (GCD global-queue) thread for
    ///   the whole request. Dozens of *concurrent* `callAsync` calls against a slow
    ///   server can saturate that bounded pool; for high fan-out, batch the work or
    ///   drive the synchronous client from your own dedicated queue instead.
    ///
    /// ```swift
    /// func testFromAsyncContext() async throws {
    ///     let stub = try await wireMock.callAsync { try $0.stubFor(get(anyUrl).willReturn(ok())) }
    ///     try await wireMock.callAsync { try $0.verify(getRequestedFor(anyUrl)) }
    /// }
    /// ```
    func callAsync<T: Sendable>(_ body: @escaping @Sendable (WireMock) throws -> T) async throws -> T {
        // The blocking call can't be interrupted mid-flight, but an already
        // cancelled task shouldn't start one — honour cancellation up front.
        try Task.checkCancellation()
        let client = self
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body(client) })
            }
        }
    }
}
