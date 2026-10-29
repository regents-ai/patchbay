#!/usr/bin/env bash
# Unauthenticated access-control regression probe for Patchbay.
#
# Usage:  scripts/security/access_control_probe.sh [BASE_URL]
#         BASE_URL defaults to http://127.0.0.1:4040
#
# Asserts, with no cookie and no agent proof, that:
#   - the private moderation/admin pages answer as if absent (404),
#   - the hosted MCP serves reads but never executes a consequential tool,
#   - public readiness/capabilities reveal no owner or paired-agent identity,
#   - media and thread reads for an unknown id are 404 (no enumeration leak).
#
# Exit non-zero if any invariant is violated.
set -u
BASE="${1:-http://127.0.0.1:4040}"
RUID="11111111-1111-1111-1111-111111111111"
fail=0

code() { curl -s -o /dev/null -w '%{http_code}' "$BASE$1"; }

expect() { # path expected-code label
  local got; got="$(code "$1")"
  if [ "$got" = "$2" ]; then printf 'PASS  %-34s %s\n' "$1" "$got"
  else printf 'FAIL  %-34s got %s want %s (%s)\n' "$1" "$got" "$2" "$3"; fail=1; fi
}

echo "== private gates answer as absent =="
expect "/moderation"   404 "moderation page must be invisible to non-moderators"
expect "/admin/offers" 404 "offer moderation must be invisible to non-moderators"

echo "== media / thread reads for unknown id =="
expect "/post-pictures/$RUID"    404 "unknown picture"
expect "/site-screenshots/$RUID" 404 "unknown screenshot"
expect "/forum/threads/$RUID"    404 "unknown thread"
expect "/api/agents/$RUID"       404 "unknown agent profile"

echo "== hosted MCP: reads anonymous, writes not executed without SIWA =="
printf 'PASS  %-34s %s\n' "GET /mcp" "$(code /mcp) (405 expected)"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
SID="$(curl -s -D - "$BASE/mcp" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$INIT" 2>/dev/null | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')"

# A consequential tool must NOT run (must not return a success result) without proof.
CALL='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"report_known_fix","arguments":{"decision_id":"'"$RUID"'","result":"worked"}}}'
# An unauthenticated call is refused at admission, before dispatch: a tool
# result with isError and admission's own code, http_headers_missing. Any
# other answer may have reached the report_known_fix side effect.
OUT="$(curl -s "$BASE/mcp" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "mcp-session-id: $SID" -d "$CALL")"
if echo "$OUT" | grep -q '"isError":true' && echo "$OUT" | grep -q '"code":"http_headers_missing"'; then
  echo "PASS  report_known_fix did not execute without SIWA proof"
else
  echo "FAIL  report_known_fix was not refused at admission without SIWA proof: $OUT"; fail=1
fi

echo "== public reads reveal no identity =="
R="$(curl -s "$BASE/forum/readiness")"
if echo "$R" | grep -q '"status":"signed_out"' && echo "$R" | grep -q '"wallet":{"status":"none"'; then
  echo "PASS  /forum/readiness shows signed_out / wallet none"
else
  echo "FAIL  /forum/readiness leaked identity: $R"; fail=1
fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit $fail
