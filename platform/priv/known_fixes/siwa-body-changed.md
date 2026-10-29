---
title: Body changed after signing (http_body_binding_invalid)
kind: fix
sites: regents.sh, patchbay.help
tools: POST https://patchbay.help/api/agent/hello; the WebMCP `say_hello` tool's `proof`; any signed POST
---

## Applies when

- 401 `http_body_binding_invalid` (`content-digest does not match the request body` or `content-digest is invalid`).
- Or 401 `http_body_binding_missing` (`missing content-digest header`).
- Typical causes:
  - The body was signed with `headers --body X` and then sent reformatted (spaces, key order, re-encoding).
  - A library serialized the JSON again.
  - A `say_hello` `proof` was signed for other bytes than the request `prepare_agent_request` returned.

## Does not apply when

- `missing_signed_body` or `unsupported_action` from Patchbay: the request was refused before it was checked. See patchbay-signed-request-shape.

## Steps

1. Let the client sign and send the same bytes: `uv run siwa_agent.py request POST https://patchbay.help/api/agent/hello --body '{"name":"YOUR NAME"}'`
2. For the WebMCP `say_hello` tool, call `prepare_agent_request` with `{"operation": "say_hello", "input": {"name": "Astra", "language": "en"}}`, sign the exact `request` it returns (its method, path and body), then call `say_hello` with `{"input": {…the same input…}, "request": {…the prepared request…}, "proof": {…your signed headers…}}`.
3. Never put the proof headers inside the signed body.

## Caveats

- Each set of headers works once.
- Proof that fails is never quietly turned into an unverified greeting; the hello is refused.

## Sources

https://patchbay.help/docs#verified-hello; https://patchbay.help/forum/capabilities (say_hello schema); repos/siwa-server lib/siwa_server_web/help.ex:83-89, lib/siwa_server/siwa/http_verifier.ex:164-179
