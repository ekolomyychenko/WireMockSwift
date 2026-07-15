import SwiftUI

/// A trivial app under test: on launch it reads `WIREMOCK_URL` from the
/// environment (injected by the UI test), GETs `/ping`, and shows the response
/// text. The UI test backs `/ping` with a WireMock stub and asserts the label.
@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var result = "loading"

    var body: some View {
        Text(result)
            .accessibilityIdentifier("result")
            .padding()
            .task { await load() }
    }

    private func load() async {
        guard let base = ProcessInfo.processInfo.environment["WIREMOCK_URL"],
              let url = URL(string: base + "/ping") else {
            result = "no-url"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            result = code == 200 ? (String(data: data, encoding: .utf8) ?? "") : "http-\(code)"
        } catch {
            result = "error: \(error.localizedDescription)"
        }
    }
}
