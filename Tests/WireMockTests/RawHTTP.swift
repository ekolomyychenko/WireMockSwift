import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal raw HTTP/1.1 client over a TCP socket.
///
/// `URLSession`/`HTTPURLResponse` hide two things we need to assert on the wire:
/// the server's custom *reason phrase* (from `withStatusMessage`) and *duplicate*
/// response headers (e.g. multiple `Set-Cookie`). This reads the raw bytes so
/// those are observable. A receive timeout guards against hangs.
enum RawHTTP {
    enum Failure: Error, CustomStringConvertible {
        case socket, connect, send, empty
        var description: String {
            switch self {
            case .socket: return "raw socket creation failed"
            case .connect: return "raw socket connect failed"
            case .send: return "raw socket send failed"
            case .empty: return "raw socket read returned no data"
            }
        }
    }

    /// Sends `GET path` and returns the full raw response (status line, headers,
    /// blank line, body). Uses `Connection: close` so the read completes at EOF.
    static func get(
        path: String,
        host: String = "127.0.0.1",
        port: UInt16 = 8080,
        timeoutSeconds: Int = 5
    ) throws -> String {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif

        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw Failure.socket }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        let connected = withUnsafePointer(to: &addr) { rawPtr in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure.connect }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent >= 0 else { throw Failure.send }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
        }
        guard !response.isEmpty else { throw Failure.empty }
        return String(decoding: response, as: UTF8.self)
    }

    /// The status line (first line) of the response, e.g. `HTTP/1.1 418 I'm a teapot`.
    static func statusLine(path: String, port: UInt16 = 8080) throws -> String {
        let raw = try get(path: path, port: port)
        return raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// All values of a (possibly repeated) response header, in order.
    static func headerValues(_ name: String, path: String, port: UInt16 = 8080) throws -> [String] {
        let raw = try get(path: path, port: port)
        // Headers end at the first blank line.
        let headerBlock = raw.components(separatedBy: "\r\n\r\n").first ?? raw
        let prefix = name.lowercased() + ":"
        return headerBlock.split(separator: "\r\n").compactMap { line in
            let lower = line.lowercased()
            guard lower.hasPrefix(prefix) else { return nil }
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
    }
}
