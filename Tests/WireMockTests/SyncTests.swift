import XCTest
@testable import WireMock

/// Unit tests for the synchronous bridge `WireMockSync.run` — the escape hatch
/// that runs an async operation from a synchronous XCTest body. No server needed.
final class SyncTests: XCTestCase {
    func testRunReturnsValue() throws {
        let value = try WireMockSync.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testRunReturnsAsyncComputedValue() throws {
        let value = try WireMockSync.run {
            try await Task.sleep(nanoseconds: 5_000_000)
            return "done"
        }
        XCTAssertEqual(value, "done")
    }

    func testRunPropagatesThrownError() {
        struct Boom: Error {}
        XCTAssertThrowsError(try WireMockSync.run { throw Boom() }) { error in
            XCTAssertTrue(error is Boom, "underlying error must propagate, got \(error)")
        }
    }

    func testRunTimesOutAndCancels() {
        // The operation runs longer than the timeout: run() must give up, throw
        // .transport, and cancel the in-flight task (observed via the cancel flag).
        let observedCancellation = Expectation()
        XCTAssertThrowsError(
            try WireMockSync.run(timeout: 0.1) {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)  // 5s, far past the timeout
                } catch is CancellationError {
                    observedCancellation.fulfill()
                    throw CancellationError()
                }
                return "should not reach here"
            }
        ) { error in
            guard case WireMockError.transport(let underlying)? = error as? WireMockError else {
                return XCTFail("expected .transport timeout, got \(error)")
            }
            XCTAssertTrue(underlying.contains("timed out"), "message should mention the timeout, got \(underlying)")
        }
        // Give the cancelled task a moment to observe cancellation.
        XCTAssertTrue(observedCancellation.wait(seconds: 2), "run() must cancel the in-flight task on timeout")
    }
}

/// Minimal thread-safe one-shot signal (avoids XCTestExpectation's main-run-loop
/// coupling in a synchronous test body).
private final class Expectation: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func fulfill() { semaphore.signal() }
    func wait(seconds: TimeInterval) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
}
