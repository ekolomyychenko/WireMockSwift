#!/usr/bin/env bash
# Public-API stability gate for the WireMock module. The library's whole value is
# a stable Swift API mirroring Java WireMock, so an accidental signature change
# should fail the build, not ship silently.
#
#   Scripts/api-check.sh            # compare current API against the baseline
#   Scripts/api-check.sh --update   # regenerate the baseline (intentional change)
#
# The baseline (api/WireMock.api.json) is an api-digester SDK dump. Its element
# ORDER is non-deterministic, so it is never diffed textually — it is only fed to
# `-diagnose-sdk`, which compares semantically and reports added/removed/changed
# declarations. Any reported change fails the gate; run with --update after an
# intentional API change and commit the new baseline.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE="api/WireMock.api.json"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx12.0"
INCLUDES=(-I .build/debug/Modules -I .build/debug)

# The WireMock module links XCTest by design (the reporter seam's XCTActivityReporter
# and the assertion helpers), so the digester must be able to *load* XCTest to read
# the module at all. Newer toolchains (e.g. the macOS 26 SDK) don't put XCTest on the
# digester's default search path, so it fails with "missing required module 'XCTest'"
# and emits an EMPTY dump, making every symbol read as "removed" (a false release-blocking
# alarm, or a real total break we'd never see the shape of). Two defences below: this
# search-path fix, PLUS a hard non-empty-dump assertion + captured stderr, so an empty
# dump fails loudly instead of masquerading as an API change (it bit us once). Point at
# the platform's Developer frameworks when present so the module loads; this only adds a
# search path, never changes which symbols WireMock exposes, so it is a no-op on
# toolchains that already resolve XCTest.
XCTEST_FW="$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
FRAMEWORKS=()
[ -d "$XCTEST_FW/XCTest.framework" ] && FRAMEWORKS=(-F "$XCTEST_FW")

# A stable public symbol that MUST appear in any non-empty WireMock dump. If a dump
# lacks it, the digester produced an empty module (the "XCTest failed to load" mode
# described above) — a hard failure, not a silent false-negative. Guards both the
# --update baseline (never commit an empty one) and the compare probe below.
SENTINEL_SYMBOL='"printedName": "RequestExpectation"'
assert_dump_has_symbols() {
  local dump="$1" what="$2"
  if [ ! -s "$dump" ] || ! grep -q "$SENTINEL_SYMBOL" "$dump"; then
    echo "::error::empty/symbol-less API dump ($what) — the digester could not read the WireMock module." >&2
    echo "  This is usually XCTest failing to load for swift-api-digester on this toolchain." >&2
    echo "  Fix the module load (see the XCTEST_FW note in this script); do NOT treat it as an API change." >&2
    exit 1
  fi
}

swift build >/dev/null

if [ "${1:-}" = "--update" ]; then
  mkdir -p api
  # Expand a possibly-empty array under `set -u` (bash 3.2 on stock macOS treats
  # "${arr[@]}" of an empty array as unbound), matching Scripts/start-wiremock.sh.
  xcrun swift-api-digester -dump-sdk -module WireMock -o "$BASELINE" \
    "${INCLUDES[@]}" ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} -sdk "$SDK" -target "$TARGET"
  assert_dump_has_symbols "$BASELINE" "regenerated baseline"
  echo "Baseline regenerated at $BASELINE — review and commit it."
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "::error::no API baseline at $BASELINE — run Scripts/api-check.sh --update" >&2
  exit 1
fi

REPORT="$(mktemp)"
CURRENT="$(mktemp)"
ERRLOG="$(mktemp)"
trap 'rm -f "$REPORT" "$CURRENT" "$ERRLOG"' EXIT

# Probe: dump the CURRENT module independently and assert it has symbols BEFORE
# diagnosing. Without this, an empty current dump makes -diagnose-sdk report every
# symbol as "removed" — indistinguishable from a real total break, and the exact
# false alarm the XCTEST_FW note describes. Fail loudly here instead.
xcrun swift-api-digester -dump-sdk -module WireMock -o "$CURRENT" \
  "${INCLUDES[@]}" ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} -sdk "$SDK" -target "$TARGET" 2>"$ERRLOG" || {
    echo "::error::swift-api-digester -dump-sdk failed:" >&2; cat "$ERRLOG" >&2; exit 1
  }
assert_dump_has_symbols "$CURRENT" "current module"

# Capture stderr (was blindly discarded). A "missing required module" here means the
# module didn't load — treat it as a hard failure rather than swallowing it and diffing
# a degraded report.
xcrun swift-api-digester -diagnose-sdk -baseline-path "$BASELINE" -module WireMock \
  "${INCLUDES[@]}" ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} -sdk "$SDK" -target "$TARGET" -o "$REPORT" 2>"$ERRLOG" || true
if grep -qiE 'missing required module|error:' "$ERRLOG"; then
  echo "::error::swift-api-digester -diagnose-sdk reported a load/tooling error:" >&2
  cat "$ERRLOG" >&2
  exit 1
fi

# The report is section headers (/* … */) and blank lines; any other line is a
# real API change (e.g. "Func foo(_:) has been removed").
#
# `SendableMetatype` lines are filtered out: it is a compiler-implicit supertype
# of `Sendable` (split out in Swift 6.2) that the digester emits only on newer
# toolchains. The baseline is generated on whatever local toolchain the author
# runs; CI's may be older/newer, so every `Sendable` type would otherwise report
# a spurious added/removed `SendableMetatype` conformance. It is never declared,
# so it is not part of the API contract — and a genuine `Sendable` removal still
# surfaces its own separate "removed conformance to Sendable" line.
CHANGES="$(grep -vE '^\s*$|^/\*.*\*/\s*$|SendableMetatype' "$REPORT" || true)"
if [ -n "$CHANGES" ]; then
  echo "::error::public API changed vs baseline. If intentional, run Scripts/api-check.sh --update and commit."
  echo "--- API changes ---"
  echo "$CHANGES"
  exit 1
fi
echo "Public API matches the baseline."
