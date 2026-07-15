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

swift build >/dev/null

if [ "${1:-}" = "--update" ]; then
  mkdir -p api
  xcrun swift-api-digester -dump-sdk -module WireMock -o "$BASELINE" \
    "${INCLUDES[@]}" -sdk "$SDK" -target "$TARGET"
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
  "${INCLUDES[@]}" -sdk "$SDK" -target "$TARGET" -o "$REPORT" 2>/dev/null

# The report is section headers (/* … */) and blank lines; any other line is a
# real API change (e.g. "Func foo(_:) has been removed").
CHANGES="$(grep -vE '^\s*$|^/\*.*\*/\s*$' "$REPORT" || true)"
if [ -n "$CHANGES" ]; then
  echo "::error::public API changed vs baseline. If intentional, run Scripts/api-check.sh --update and commit."
  echo "--- API changes ---"
  echo "$CHANGES"
  exit 1
fi
echo "Public API matches the baseline."
