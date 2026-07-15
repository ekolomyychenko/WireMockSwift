#!/usr/bin/env bash
# Capture canonical response shapes from a real WireMock server into on-disk
# fixtures, so the pure-decode contract tests (RecordedContractTests) pin the
# library's decoders against what the *actual* pinned server emits — not against
# hand-transcribed literals that can silently drift from reality.
#
#   Scripts/capture-fixtures.sh            # uses a server on :8080 or starts one
#   WIREMOCK_URL=http://host:port Scripts/capture-fixtures.sh
#
# Volatile fields (ids, timestamps, timings, uptime) are normalised to stable
# placeholders so a re-capture against an UNCHANGED server yields a byte-identical
# tree — a non-empty `git diff Tests/WireMockTests/Fixtures` then means the wire
# format (or our capture) actually changed and the decoders must be re-checked.
set -euo pipefail
cd "$(dirname "$0")/.."

FIX_DIR="Tests/WireMockTests/Fixtures"
mkdir -p "$FIX_DIR"

PORT="${WIREMOCK_PORT:-8080}"
BASE="${WIREMOCK_URL:-http://localhost:$PORT}"
STARTED=0
if [ -z "${WIREMOCK_URL:-}" ] && ! curl -sf "$BASE/__admin/health" >/dev/null 2>&1; then
  echo "No server at $BASE — starting the pinned one…"
  Scripts/start-wiremock.sh
  STARTED=1
  BASE="http://localhost:$PORT"
fi
trap '[ "$STARTED" = 1 ] && [ -f .wiremock.pid ] && kill "$(cat .wiremock.pid)" 2>/dev/null; rm -f .wiremock.pid' EXIT

adm() { curl -sf "$BASE/__admin/$1" "${@:2}"; }

echo "Resetting server to a known baseline…"
adm reset -X POST >/dev/null

# Normalises volatile fields to stable placeholders, recursively, and pretty-prints
# with sorted keys so the output is deterministic across runs.
normalise() {
  python3 - "$1" <<'PY'
import json, re, sys
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
FIXED_UUID = "00000000-0000-0000-0000-000000000000"
ZERO_KEYS = {"timeOffsetNanos", "serveTime", "totalTime", "addedDelay",
             "processTime", "responseSendTime", "uptimeInSeconds", "loggedDate"}
FIXED_TS = "2024-01-01T00:00:00Z"
# Environment noise (curl version, IPv4-vs-IPv6 loopback) that would otherwise make
# a re-capture on a different machine/CI produce a spurious diff.
STRING_FIXED = {"clientIp": "127.0.0.1", "User-Agent": "curl", "Host": "localhost"}

def norm(v, key=None):
    if isinstance(v, dict):
        return {k: norm(val, k) for k, val in v.items()}
    if isinstance(v, list):
        return [norm(x, key) for x in v]
    if key in ("id", "stubMappingId") and isinstance(v, str):
        return FIXED_UUID
    if key in ZERO_KEYS and isinstance(v, (int, float)):
        return 0
    if key in ("loggedDateString", "timestamp") and isinstance(v, str):
        return FIXED_TS
    if key in STRING_FIXED and isinstance(v, str):
        return STRING_FIXED[key]
    if isinstance(v, str) and UUID_RE.match(v):
        return FIXED_UUID
    return v

data = json.load(open(sys.argv[1]))
print(json.dumps(norm(data), indent=2, sort_keys=True))
PY
}

capture() {  # capture <fixture-name> <admin-path> [curl args…]
  local name="$1" path="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  adm "$path" "$@" > "$tmp"
  normalise "$tmp" > "$FIX_DIR/$name.json"
  rm -f "$tmp"
  echo "  wrote $FIX_DIR/$name.json"
}

echo "Building server state and capturing fixtures…"

# 1) A rich stub + one matched and one unmatched request → mappings, serve events
#    (matched + unmatched-with-subEvents), and a LoggedRequest.
adm mappings -X POST -H 'Content-Type: application/json' -d '{
  "request": {"method":"POST","urlPath":"/form","headers":{"Content-Type":{"equalTo":"application/x-www-form-urlencoded"}}},
  "response": {"status":201,"body":"ok","headers":{"X-A":"1"}}
}' >/dev/null
curl -sf -X POST "$BASE/form" -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Cookie: session=abc' --data 'name=bob&age=3' >/dev/null || true
curl -s -o /dev/null "$BASE/no-such-stub-unmatched" || true

capture mappings-list  mappings
capture serve-events   requests
capture settings       settings   # captured before we mutate settings below

# 2) Near miss for an explicit request pattern.
capture near-misses near-misses/request-pattern -X POST -H 'Content-Type: application/json' \
  -d '{"method":"GET","url":"/expected"}'

# 3) Scenario state via a stateful stub.
adm mappings -X POST -H 'Content-Type: application/json' -d '{
  "request": {"method":"GET","urlPath":"/scenario"},
  "response": {"status":200},
  "scenarioName":"flow","requiredScenarioState":"Started","newScenarioState":"next"
}' >/dev/null
capture scenarios scenarios

# 4) Global settings echo (POST then GET the canonical shape).
adm settings -X POST -H 'Content-Type: application/json' \
  -d '{"fixedDelay":5,"proxyPassThrough":true,"extended":{"custom":1}}' >/dev/null
capture settings settings

# 5) Recording status.
capture recording-status recordings/status

# 6) Snapshot result (proxy a request to a dead sub-path so it is journalled, then
#    snapshot it into a mapping without persisting).
adm reset -X POST >/dev/null
adm mappings -X POST -H 'Content-Type: application/json' \
  -d "{\"request\":{\"method\":\"GET\",\"urlPath\":\"/snapme\"},\"response\":{\"proxyBaseUrl\":\"$BASE/nowhere\"}}" >/dev/null
curl -s -o /dev/null "$BASE/snapme" || true
capture snapshot recordings/snapshot -X POST -H 'Content-Type: application/json' -d '{"persist":false}'

adm reset -X POST >/dev/null
echo "Done. Review with: git diff $FIX_DIR"
