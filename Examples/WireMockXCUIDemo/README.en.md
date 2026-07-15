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
> In CI the device is selected automatically — see the `ios-xcuitest` job in `.github/workflows/ci.yml`.

The `.xcodeproj` is generated from `project.yml` (not committed to git — run `xcodegen generate`).
