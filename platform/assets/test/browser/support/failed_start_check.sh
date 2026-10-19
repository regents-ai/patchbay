#!/bin/sh
# A walk whose server can't start must leave no database and no saved sign-ins
# behind. The port the server asks for is already taken, so `mix phx.server` fails
# after serve.sh has made the database and signed the walk's people in; serve.sh
# must then exit with an error and drop both.
set -u
cd "$(dirname "$0")/../../.."

port=$(node -e "const s = require('node:net').createServer().listen(0, '127.0.0.1', () => { console.log(s.address().port); s.close() })")
node -e "require('node:net').createServer().listen($port, '127.0.0.1'); setTimeout(() => {}, 600000)" &
holder=$!
trap 'kill $holder 2>/dev/null' EXIT

log=$(mktemp)
PATCHBAY_DEV_PARTITION="_browser_$port" PORT=$port test/browser/support/serve.sh > "$log" 2>&1 &
server=$!
# phx.server fails to bind and exits; give it the time a cold start needs.
waited=0
while kill -0 $server 2>/dev/null && [ $waited -lt 240 ]; do sleep 1; waited=$((waited + 1)); done
if kill -0 $server 2>/dev/null; then
  kill $server
  echo "failed start check: the server was still running after ${waited}s"
  exit 1
fi
wait $server
status=$?

left=$(psql -h 127.0.0.1 -U "${PATCHBAY_DB_USERNAME:-${USER:-postgres}}" -d postgres -Atc \
  "select count(*) from pg_database where datname = 'patchbay_dev_browser_$port'")

signins=$([ -e "test/browser/.auth/_browser_$port" ] && echo left || echo none)

# It must have got as far as starting the server, which fails on the taken port.
reached=$(grep -c -i "eaddrinuse" "$log")
rm -f "$log"

echo "failed start check: serve.sh exit $status, port refused $reached time(s), databases left for port $port: $left, sign-ins: $signins"
[ "$status" -ne 0 ] && [ "$reached" -gt 0 ] && [ "$left" = "0" ] && [ "$signins" = "none" ]
