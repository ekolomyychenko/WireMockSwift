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
# and — because stderr is suppressed below — silently emits an EMPTY dump, making every
# symbol read as "removed" (a false release-blocking alarm, or a real total break we'd
# never see the shape of). Point at the platform's Developer frameworks when present so
# the module loads; this only adds a search path, never changes which symbols WireMock
# exposes, so it is a no-op on toolchains that already resolve XCTest.
XCTEST_FW="$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
FRAMEWORKS=()
[ -d "$XCTEST_FW/XCTest.framework" ] && FRAMEWORKS=(-F "$XCTEST_FW")

swift build >/dev/null

if [ "${1:-}" = "--update" ]; then
  mkdir -p api
  # Expand a possibly-empty array under `set -u` (bash 3.2 on stock macOS treats
  # "${arr[@]}" of an empty array as unbound), matching Scripts/start-wiremock.sh.
  xcrun swift-api-digester -dump-sdk -module WireMock -o "$BASELINE" \
    "${INCLUDES[@]}" ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} -sdk "$SDK" -target "$TARGET"
  echo "Baseline regenerated at $BASELINE — review and commit it."
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "::error::no API baseline at $BASELINE — run Scripts/api-check.sh --update" >&2
  exit 1
fi

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT
xcrun swift-api-digester -diagnose-sdk -baseline-path "$BASELINE" -module WireMock \
  "${INCLUDES[@]}" ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} -sdk "$SDK" -target "$TARGET" -o "$REPORT" 2>/dev/null

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
