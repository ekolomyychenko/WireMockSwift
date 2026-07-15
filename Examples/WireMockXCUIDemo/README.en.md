# WireMockXCUIDemo

[🇷🇺 Русский](README.md) · **🇬🇧 English**

A verified example: **WireMockSwift from an XCUITest on an iOS simulator**. The test runner (on the
simulator) configures a stub through the `WireMock` client, the app under test calls the same server
over `localhost` (the simulator forwards it to the host), and we verify the request.

The server (jar **or** Docker) runs **on the host** — it isn't reachable from inside the iOS bundle.
The port isn't hard-coded: the test reads the address from `WIREMOCK_URL` (default `http://localhost:8080`).

## Running

```bash
# 1. Project (generated from project.yml)
brew install xcodegen        # if not already installed
xcodegen generate

# 2. WireMock on the host (any port)
java -jar wiremock-standalone-3.13.2.jar --port 8080 --disable-banner &
for i in $(seq 1 30); do curl -sf http://localhost:8080/__admin/health && break; sleep 1; done

# 3. XCUITest on a simulator (substitute any installed simulator)
xcodebuild test -project WireMockXCUIDemo.xcodeproj -scheme SampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

> Substitute the simulator name/version for one installed on your machine (`xcrun simctl list devices available`).
> CI doesn't test a single device: the `ios-xcuitest` job runs the example across an iOS-major matrix
> (16 floor / 17 / 18 / 26 + an iPad cell), each cell pinning its own runtime (see `.github/workflows/ci.yml`).
>
> **On green-skips:** if the server is unreachable (or you accidentally target a real device rather
> than a simulator — `localhost` isn't forwarded to the host there), the test `XCTSkip`s by default and
> the run looks green. To make unreachability **fail**, run with `TEST_RUNNER_WIREMOCK_REQUIRED=1`
> (Xcode forwards it to the runner as `WIREMOCK_REQUIRED=1`) — which is exactly what CI does.

The `.xcodeproj` is generated from `project.yml` (not committed to git — run `xcodegen generate`).
