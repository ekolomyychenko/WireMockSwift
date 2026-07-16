import Foundation

// MARK: - Reporter seam (reporting-friendly, framework-agnostic)
//
// A thin, injectable hook so `stubFor` / `verify` / `expect` / `verifyInOrder`
// can surface as *steps* in a test report without the core library depending on
// any specific test/reporting framework. The default is a no-op, so behaviour is
// unchanged and nothing is forced on callers.
//
// `XCTActivityReporter` wraps each step in `XCTContext.runActivity`, which Xcode
// records as an activity in the `.xcresult` bundle. Allure (and AppCode, and the
// native Xcode Test Report navigator) turn those activities into steps *after the
// fact* — so you get Allure steps with zero Allure dependency in this code. The
// full request/stub JSON rides along as an activity attachment.

/// A hook that wraps a unit of work so a test report can render it as a step.
///
/// Inject one via `WireMock(..., reporter:)`. The default (`NoopReporter`) does
/// nothing but run the work, so it is safe everywhere — including outside a live
/// test context (SwiftUI previews, sample apps) where a real `XCTActivity` would
/// crash. Swap in `XCTActivityReporter` from a test's setup to emit steps; swap
/// in your own to target a different framework (e.g. a future swift-testing one).
public protocol WireMockReporter: Sendable {
    /// Runs `body`, optionally recording it as a named step with an attached JSON
    /// body. Must call `body` exactly once and propagate its result and errors, so
    /// wrapping never changes observable behaviour.
    ///
    /// (Declared `throws` rather than `rethrows`: `XCTContext.runActivity` takes a
    /// non-throwing block, so an implementation can't let `body`'s error propagate
    /// through it — every call site here already runs a throwing body under `try`.)
    ///
    /// - Parameters:
    ///   - name: Short one-line step title (e.g. `"Verify: POST /login"`).
    ///   - jsonBody: Optional full detail (WireMock-style JSON) to attach.
    ///
    /// `body` is `@Sendable` and `T` is `Sendable` so a reporter may bridge the
    /// work onto another actor (e.g. `XCTContext.runActivity` runs on the main
    /// actor) and hand the result back. Every wrapped call in this library passes
    /// a closure that captures only `Sendable` values and returns a `Sendable` one.
    func step<T: Sendable>(_ name: String, jsonBody: String?, _ body: @Sendable () throws -> T) throws -> T
}

/// The default reporter: runs the work and records nothing. Never touches XCTest,
/// so it can't crash outside a test context.
public struct NoopReporter: WireMockReporter {
    public init() {}
    public func step<T: Sendable>(_ name: String, jsonBody: String?, _ body: @Sendable () throws -> T) throws -> T {
        try body()
    }
}

#if canImport(XCTest)
import XCTest

/// A reporter that records each step as an `XCTActivity`. Set it from a test's
/// `setUp` (`WireMock(..., reporter: XCTActivityReporter())`) to get nested
/// activities in the Xcode Test Report — which Allure then reads from the
/// `.xcresult` as steps, with the JSON body as a step attachment.
///
/// - Important: `XCTContext.runActivity` requires a live test context and the
///   right thread — it **throws/crashes** if called outside a running test (e.g.
///   from `callAsync`'s background hop). The library disables reporting inside
///   `callAsync` for exactly this reason; use this reporter from synchronous test
///   bodies.
public struct XCTActivityReporter: WireMockReporter {
    public init() {}
    public func step<T: Sendable>(_ name: String, jsonBody: String?, _ body: @Sendable () throws -> T) throws -> T {
        // `runActivity` is @MainActor. Synchronous XCTest test bodies run on the
        // main thread, so assert main-actor isolation and bridge synchronously —
        // no real actor hop happens. (Reporting is disabled on `callAsync`'s
        // background hop, so in supported usage this is never reached off-main.)
        try MainActor.assumeIsolated {
            try XCTContext.runActivity(named: name) { activity in
                if let jsonBody {
                    let attachment = XCTAttachment(string: jsonBody)
                    attachment.name = name
                    attachment.lifetime = .keepAlways   // keep on success too, for Allure
                    activity.add(attachment)
                }
                return try body()
            }
        }
    }
}
#endif
