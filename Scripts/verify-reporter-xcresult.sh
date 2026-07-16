#!/usr/bin/env bash
# Reporter-seam .xcresult guard — proves the LIBRARY's headline feature end to end.
#
# The hermetic ReporterTests already pin the seam contract (right step names/bodies,
# body-run-once, error transparency) and that XCTActivityReporter is crash-free. What
# they CANNOT observe server-less is the report-SIDE output: that the emitted
# XCTActivity steps and their WireMock-JSON XCTAttachments actually land in the
# `.xcresult` (the thing Allure/Xcode read as steps). This script closes exactly that
# gap so a regression that stops emitting steps/attachments fails a run, not a manual
# eyeball.
#
# `swift test` does not produce an `.xcresult`, so we drive the live
# ReporterIntegrationTests through `xcodebuild test`, then assert with
# `xcresulttool export attachments` that the Stub/Verify/Capture attachments are present.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="WireMockSwift"
ONLY="WireMockTests/ReporterIntegrationTests"
WORK="$(mktemp -d)"
BUNDLE="$WORK/Reporter.xcresult"
ATTACH="$WORK/attachments"
trap 'rm -rf "$WORK"' EXIT

# The integration test XCTSkips without a live server — which would emit ZERO steps and
# make this guard meaningless. Require the server (start it if needed) and force
# fail-not-skip via WIREMOCK_REQUIRED (a macOS unit test inherits the shell env).
PORT="${WIREMOCK_PORT:-8080}"
if ! curl -fs "http://localhost:${PORT}/__admin/mappings" >/dev/null 2>&1; then
  echo "WireMock not reachable on ${PORT} — starting it ..."
  Scripts/start-wiremock.sh
fi

echo "Running $ONLY through xcodebuild (produces an .xcresult) ..."
if ! WIREMOCK_REQUIRED=1 xcodebuild test \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -only-testing:"$ONLY" \
    -resultBundlePath "$BUNDLE" \
    >"$WORK/xcodebuild.log" 2>&1; then
  echo "::error::xcodebuild test failed for $ONLY"
  tail -40 "$WORK/xcodebuild.log"
  exit 1
fi

echo "Exporting attachments from the result bundle ..."
xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$ATTACH" >/dev/null
MANIFEST="$ATTACH/manifest.json"
[ -f "$MANIFEST" ] || { echo "::error::no manifest.json produced under $ATTACH"; exit 1; }

# Every step surfaces one attachment; the suggested name is the step title with the
# ':'/'/' sanitised out (e.g. "Stub: GET /reporter-demo" -> "Stub GET reporter-demo…").
# Require all three seam kinds (stubFor / verify / expect-terminal) to have landed.
if ! jq -e '
      [ .[].attachments[].suggestedHumanReadableName ] as $n
      | ($n | any(startswith("Stub")))
        and ($n | any(startswith("Verify")))
        and ($n | any(startswith("Capture")))
    ' "$MANIFEST" >/dev/null; then
  echo "::error::reporter attachments missing from the .xcresult — expected Stub/Verify/Capture steps."
  echo "--- attachment names found ---"
  jq -r '.[].attachments[].suggestedHumanReadableName' "$MANIFEST" || true
  echo "(If this run used NoopReporter, that is the expected failure — the guard works.)"
  exit 1
fi

# Prove the JSON body rode along as attachment content, not just an empty step marker.
if ! find "$ATTACH" -name '*.txt' -exec sh -c 'jq -e . "$1" >/dev/null 2>&1' _ {} \; -print -quit | grep -q .; then
  echo "::error::no attachment body parses as JSON — the WireMock-JSON payload did not ride along."
  exit 1
fi

echo "Reporter .xcresult guard passed: Stub/Verify/Capture steps with JSON attachments landed."
