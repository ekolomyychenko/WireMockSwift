#!/usr/bin/env bash
# Download (if absent), start, and wait for the pinned WireMock standalone server.
# Reused by CI (the macos and ios-xcuitest jobs) and by Scripts/test.sh, so the
# version pin and readiness gate live in exactly one place.
#
# Env: WIREMOCK_VERSION (default 3.13.2), WIREMOCK_PORT (default 8080).
# Writes the server PID to .wiremock.pid for callers that want to stop it.
set -euo pipefail

WIREMOCK_VERSION="${WIREMOCK_VERSION:-3.13.2}"
PORT="${WIREMOCK_PORT:-8080}"
JAR="wiremock-standalone-${WIREMOCK_VERSION}.jar"
URL="https://repo1.maven.org/maven2/org/wiremock/wiremock-standalone/${WIREMOCK_VERSION}/${JAR}"

if [ ! -f "$JAR" ]; then
  echo "Downloading $JAR ..."
  curl -sSL -o "$JAR" "$URL"
fi

echo "Starting WireMock $WIREMOCK_VERSION on port $PORT ..."
java -jar "$JAR" --port "$PORT" --disable-banner &
echo $! > .wiremock.pid

for _ in $(seq 1 30); do
  curl -sf "http://localhost:${PORT}/__admin/health" >/dev/null && break
  sleep 1
done
curl -sf "http://localhost:${PORT}/__admin/health" >/dev/null \
  || { echo "WireMock never became ready on port $PORT" >&2; exit 1; }
echo "WireMock is ready on port $PORT."
