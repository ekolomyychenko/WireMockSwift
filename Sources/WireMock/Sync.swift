import Foundation

/// Runs an async WireMock operation synchronously — convenient inside
/// synchronous XCTest methods that don't want to be `async`.
///
/// ```swift
/// let stub = try WireMockSync.run { try await wireMock.stubFor(get(anyUrl).willReturn(ok())) }
/// ```
///
/// - Important: This blocks the calling thread until the work completes or the
///   timeout elapses. Call it from a synchronous context (e.g. a test body),
///   never from inside an `async` function, and never from a thread the
///   operation itself needs to resume on. The work runs on the Swift
///   concurrency pool, so it does not deadlock against the blocked caller.
public enum WireMockSync {
    public static func run<T: Sendable>(
        timeout: TimeInterval = 30,
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task {
            let result: Result<T, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            box.store(result)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // Abort the in-flight work so it doesn't leak a connection; the
            // admin client awaits `URLSession.data(for:)`, which honours cancel.
            task.cancel()
            throw WireMockError.transport(underlying: "Synchronous WireMock call timed out after \(timeout)s")
        }
        return try box.take()
    }
}

/// A lock-guarded one-shot box to hand a `Result` back from the `Task`.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        result = value
    }

    func take() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let result else {
            throw WireMockError.transport(underlying: "Synchronous WireMock call produced no result")
        }
        return try result.get()
    }
}
