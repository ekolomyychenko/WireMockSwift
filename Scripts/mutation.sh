#!/usr/bin/env bash
# On-demand mutation testing of the encoders (Models + DSL) with muter.
#
# This is deliberately NOT wired into the per-PR CI: mutation testing runs the
# whole test suite once per mutant and is slow. Run it locally (or in a scheduled
# job) to audit test STRENGTH — a surviving mutant reveals a vacuous assertion,
# most importantly in the self-referential golden-encoding suite.
#
#   Scripts/mutation.sh          # mutate the encoder sources and report kill rate
#
# Install muter first:  brew install muter   (or: mint install muter-mutation-testing/muter)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v muter >/dev/null 2>&1; then
  echo "muter is not installed — skipping mutation run (this gate is non-blocking)."
  echo "Install it with:  brew install muter"
  exit 0
fi

# Scope to the encoders: the model Codable types and the DSL builders that shape
# the wire JSON. Mutating the whole tree would be far slower for little extra signal.
FILES=(
  Sources/WireMock/Models
  Sources/WireMock/DSL
)

echo "Running muter over the encoders (this is slow — one test run per mutant)…"
muter run --files-to-mutate "${FILES[@]}"
