#!/usr/bin/env bash
# Local test runner for WireMockSwift.
#
#   Scripts/test.sh hermetic   # fast, NO server — pure encoding/decoding/unit
#   Scripts/test.sh            # full suite (starts a server if none is running)
#
# The integration suites share one server and reset it in setUp, so they are NOT
# parallel-safe — this always runs serially (SwiftPM's default). Point the full
# run at an existing server with WIREMOCK_URL=http://host:port.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"

# The live-server test groups (class / method name substrings). Skipping these
# leaves the hermetic subset, which needs no server.
LIVE_SKIP=(--skip Integration --skip ResponseOptions --skip Live)

case "$MODE" in
  hermetic)
    echo "Running hermetic subset (no server needed)…"
    swift test "${LIVE_SKIP[@]}"
    ;;
  all)
    PORT="${WIREMOCK_PORT:-8080}"
    STARTED=0
    if [ -z "${WIREMOCK_URL:-}" ] && ! curl -sf "http://localhost:${PORT}/__admin/health" >/dev/null 2>&1; then
      echo "No server on :$PORT — starting one…"
      Scripts/start-wiremock.sh
      STARTED=1
    fi
    trap '[ "$STARTED" = 1 ] && [ -f .wiremock.pid ] && kill "$(cat .wiremock.pid)" 2>/dev/null; rm -f .wiremock.pid' EXIT
    echo "Running full suite (unit + integration)…"
    WIREMOCK_REQUIRED=1 swift test --enable-code-coverage
    ;;
  *)
    echo "usage: Scripts/test.sh [hermetic|all]" >&2
    exit 2
    ;;
esac
