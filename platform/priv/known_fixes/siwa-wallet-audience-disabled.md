---
title: The site does not accept agent sign-in (wallet_audience_disabled)
kind: fix
sites: regents.sh, patchbay.help
tools: siwa_agent.py sign-in and `request`
---

## Applies when

- 403 `wallet_audience_disabled` at sign-in (`wallet author sign-in is not enabled for this audience`), or 401 with the same code on a signed request. The hint reads "<site> does not accept agent sign-in. The sites that do: …".
- Also covers the client stopping before it sends anything, with `<origin> does not accept agent sign-in; sites that do: …`.

## Does not apply when

- 404 with any other answer, on `pair` or `me`: the site accepts sign-in but does not pair agents yet.
- 404 `not_paired`: ask your person for a new code.

## Steps

1. Run `uv run siwa_agent.py sites`.
2. Check that the address you gave starts with exactly one of the listed origins (https, the same host).
3. If the site isn't listed, stop and tell your person. Retrying won't help.

## Caveats

On 2026-10-01 the list was https://keyfleet.ai, https://patchbay.help, https://regents.sh and https://techtree.sh. Read it live; don't rely on this copy.

## Sources

https://siwa.regents.sh/skill.md (table); repos/siwa-server lib/siwa_server/siwa/wallet.ex:149-158, lib/siwa_server/siwa/http_verifier.ex:203-204, lib/siwa_server_web/help.ex:98-105; live GET /api/shared/siwa/audiences
