#!/usr/bin/env bash
# Download (if absent), start, and wait for the pinned WireMock standalone server.
# Reused by CI (the macos and ios-xcuitest jobs) and by Scripts/test.sh, so the
# version pin and readiness gate live in exactly one place.
#
# Env: WIREMOCK_VERSION (default 3.13.2), WIREMOCK_PORT (default 8080).
#   WIREMOCK_ADMIN_AUTH  — if set (e.g. "user:pass"), start the server with
#                          `--admin-api-basic-auth` so the admin API requires
#                          Basic auth; the readiness probe then sends the creds.
#   WIREMOCK_PID_FILE    — where to write the PID (default .wiremock.pid), so a
#                          second (auth-enabled) instance doesn't clobber the first.
# Writes the server PID for callers that want to stop it.
set -euo pipefail

WIREMOCK_VERSION="${WIREMOCK_VERSION:-3.13.2}"
PORT="${WIREMOCK_PORT:-8080}"
PID_FILE="${WIREMOCK_PID_FILE:-.wiremock.pid}"
ADMIN_AUTH="${WIREMOCK_ADMIN_AUTH:-}"
JAR="wiremock-standalone-${WIREMOCK_VERSION}.jar"
URL="https://repo1.maven.org/maven2/org/wiremock/wiremock-standalone/${WIREMOCK_VERSION}/${JAR}"

if [ ! -f "$JAR" ]; then
  echo "Downloading $JAR ..."
  curl -sSL -o "$JAR" "$URL"
fi

# Optional Basic-auth on the admin API. When enabled the readiness probe must
# authenticate too, so build a matching `curl -u` argument.
AUTH_ARGS=()
PROBE_AUTH=()
if [ -n "$ADMIN_AUTH" ]; then
  AUTH_ARGS=(--admin-api-basic-auth "$ADMIN_AUTH")
  PROBE_AUTH=(-u "$ADMIN_AUTH")
  echo "Starting WireMock $WIREMOCK_VERSION on port $PORT (admin Basic auth enabled) ..."
else
  echo "Starting WireMock $WIREMOCK_VERSION on port $PORT ..."
fi

# Expand possibly-empty arrays safely: bash 3.2 (stock /bin/bash on macOS) treats
# "${arr[@]}" of an unset/empty array as an unbound variable under `set -u`.
java -jar "$JAR" --port "$PORT" --disable-banner ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} &
echo $! > "$PID_FILE"

for _ in $(seq 1 30); do
  curl -sf ${PROBE_AUTH[@]+"${PROBE_AUTH[@]}"} "http://localhost:${PORT}/__admin/health" >/dev/null && break
  sleep 1
done
curl -sf ${PROBE_AUTH[@]+"${PROBE_AUTH[@]}"} "http://localhost:${PORT}/__admin/health" >/dev/null \
  || { echo "WireMock never became ready on port $PORT" >&2; exit 1; }
echo "WireMock is ready on port $PORT."
