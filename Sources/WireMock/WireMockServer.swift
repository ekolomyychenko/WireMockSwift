#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Starts and stops an external WireMock server process from Swift, for use in
/// tests and local tooling on macOS and Linux.
///
/// WireMock is a Java server, so this spawns it as a subprocess — either the
/// standalone jar (`java -jar …`) or a Docker container. It is therefore **not
/// available on iOS/tvOS/watchOS**, where you should point `WireMock` at an
/// externally-run server instead. (This whole type is compiled out on those
/// platforms.)
///
/// ```swift
/// let server = WireMockServer(port: 8080, launch: .jar(path: "wiremock-standalone.jar"))
/// try await server.start()
/// defer { server.stop() }
/// try await server.client.stubFor(get(anyUrl).willReturn(ok()))
/// ```
public final class WireMockServer: @unchecked Sendable {
    /// How to launch the server.
    public enum Launch: Sendable {
        /// `java -jar <path> --port <port>`.
        case jar(path: String, javaPath: String = "java", extraArgs: [String] = [])
        /// `docker run --rm -p <port>:8080 <image>`.
        case docker(image: String = "wiremock/wiremock:3", extraArgs: [String] = [])
    }

    public let host = "localhost"
    public let port: Int
    private let launch: Launch
    private let lock = NSLock()
    private var process: Process?

    public init(port: Int = 8080, launch: Launch = .docker()) {
        self.port = port
        self.launch = launch
    }

    /// Base URL the server is reachable at.
    public var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    /// A `WireMock` client pointed at this server.
    public var client: WireMock { WireMock(baseURL: baseURL) }

    /// Launches the process and waits until the admin API responds.
    public func start(timeout: TimeInterval = 60) async throws {
        let process = makeProcess()
        do {
            try process.run()
        } catch {
            throw WireMockError.transport(underlying: "Failed to launch WireMock: \(error)")
        }
        storeProcess(process)

        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if !process.isRunning {
                throw WireMockError.transport(underlying: "WireMock process exited during startup (code \(process.terminationStatus))")
            }
            if await isReady() { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        stop()
        throw WireMockError.transport(underlying: "WireMock did not become ready within \(timeout)s")
    }

    deinit {
        // Signal termination but do NOT block on teardown here: deinit may run
        // on a cooperative-pool thread, where `waitUntilExit()` could stall the
        // pool. The blocking join lives only in the explicit `stop()`.
        takeProcess()?.terminate()
    }

    /// Terminates the server process, if running.
    public func stop() {
        let process = takeProcess()
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func storeProcess(_ process: Process?) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    private func takeProcess() -> Process? {
        lock.lock(); defer { lock.unlock() }
        let process = self.process
        self.process = nil
        return process
    }

    private func makeProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        switch launch {
        case let .jar(path, javaPath, extraArgs):
            process.arguments = [javaPath, "-jar", path, "--port", "\(port)", "--disable-banner"] + extraArgs
        case let .docker(image, extraArgs):
            process.arguments = ["docker", "run", "--rm", "-p", "\(port):8080", image] + extraArgs
        }
        return process
    }

    private func isReady() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("__admin/mappings"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }
}
#endif
