#!/usr/bin/env bash
# On-demand mutation testing of the encoders (Models + DSL) with muter.
#
# NOT wired into per-PR CI: mutation testing runs the whole test suite once per
# mutant and is slow. Run locally / scheduled to audit test STRENGTH — a surviving
# mutant reveals a vacuous assertion, most importantly in the golden-encoding suite.
#
#   Scripts/mutation.sh                                           # default: Models + DSL
#   Scripts/mutation.sh Sources/WireMock/DSL/WireMock+Expect.swift  # scoped to one file/dir
#
# Install muter:  brew install muter
#
# Version handling: the config SCHEMA, config FILENAME, and `--files-to-mutate`
# arity all changed in muter 16, so this script adapts to the installed version:
#   • pre-16 — uses the committed `.muter.conf.yml` and one multi-file run.
#   • 16+    — generates a temp non-dotted `muter.conf.yml`, cleans the stale
#              `.build` (whose baked-in absolute paths break muter's project copy),
#              and mutates ONE file per run. Two files are skipped under 16 because
#              its codegen regression mangles operators (`x > 0` -> `x > <`) and
#              aborts the whole run for them; their logic is covered by targeted
#              manual mutation until the upstream bug is fixed.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v muter >/dev/null 2>&1; then
  echo "muter is not installed — skipping mutation run (this gate is non-blocking)."
  echo "Install it with:  brew install muter"
  exit 0
fi

MUTER_MAJOR="$(muter --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)"

# Default scope: the encoder sources (Codable models + DSL builders that shape the
# wire JSON). Override by passing files/dirs as arguments.
if [ "$#" -gt 0 ]; then
  SCOPE=("$@")
else
  SCOPE=(Sources/WireMock/Models Sources/WireMock/DSL)
fi

# ---- pre-16: original behaviour (committed .muter.conf.yml, one multi-file run) ----
if [ "$MUTER_MAJOR" -lt 16 ]; then
  echo "Running muter $MUTER_MAJOR over ${SCOPE[*]} (slow — one test run per mutant)…"
  muter run --files-to-mutate "${SCOPE[@]}"
  exit $?
fi

# ---- 16+: adapt to the new filename/schema/arity, skip codegen-broken files ----
echo "Detected muter $MUTER_MAJOR — using the v16-compatible path."

# Files muter 16's codegen mangles (aborts the run for the file). Covered by manual
# mutation; drop entries here once the upstream codegen bug is fixed.
BROKEN_UNDER_16=(
  "Sources/WireMock/DSL/RequestExpectation.swift"
  "Sources/WireMock/DSL/CapturedRequest.swift"
)

CONF="muter.conf.yml"                       # v16 wants the NON-dotted filename
MUTATED_DIR="../$(basename "$PWD")_mutated"
cleanup() { rm -f "$CONF"; rm -rf "$MUTATED_DIR"; }
trap cleanup EXIT

# v16 config == the same hermetic command as .muter.conf.yml (no live server needed).
cat > "$CONF" <<'YAML'
executable: /usr/bin/env
arguments:
- swift
- test
- --skip
- Integration
- --skip
- ResponseOptions
- --skip
- Live
- --skip
- ContractIntegration
exclude:
- Tests
- Examples
- Snippets
- Scripts
excludeCalls: []
YAML

# Expand dirs to .swift files (v16 takes ONE file per --files-to-mutate).
FILES=()
for p in "${SCOPE[@]}"; do
  if [ -d "$p" ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(find "$p" -name '*.swift' | sort)
  else
    FILES+=("$p")
  fi
done

status=0
for f in "${FILES[@]}"; do
  if printf '%s\n' "${BROKEN_UNDER_16[@]}" | grep -qxF "$f"; then
    echo "⚠️  SKIP $f — muter $MUTER_MAJOR codegen bug aborts this file; covered by manual mutation."
    continue
  fi
  echo "── muter: $f ──"
  # Stale .build (baked-in absolute paths) breaks muter's copied project — clean first.
  rm -rf .build "$MUTATED_DIR"
  muter run --files-to-mutate "$f" || status=1
done

exit "$status"
