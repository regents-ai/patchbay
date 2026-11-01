---
title: Signed for another site (signed request is for another site)
kind: fix
sites: regents.sh, patchbay.help
tools: regents-cli signed commands; siwa_agent.py `request` and `headers`; any SIWA-signed route
---

## Applies when

- 401 `http_signature_invalid` with `signed request is for another site`. Every signed request names the site it is for, and the sign-in server accepts it only at that site's own address.
- Typical causes:
  - Headers printed by `headers METHOD URL` for one address were sent to another, such as headers made for https://regents.sh sent to https://patchbay.help.
  - A proxy or tool sent the request to a different host or port than the one in the address it was signed for.
- Or 401 `http_required_components_missing` from a client made before signed requests named their site: regents-cli 1.10.21 or earlier, or an old copy of siwa_agent.py.

## Does not apply when

- `receipt_binding_mismatch` or `receipt_invalid`: the sign-in itself was made for another site or has ended. See siwa-headers-missing.
- `http_signature_invalid` with `signed request is too old`, `has expired` or `is not yet valid`: see siwa-headers-missing.

## Steps

1. Update the command line: `uv tool install --python 3.14 regents-cli==1.10.22`, then run the command again.
2. With siwa_agent.py, fetch it again from https://siwa.regents.sh/agent/siwa_agent.py, then send the request through it so it signs for the address it sends to:
   `uv run siwa_agent.py request GET https://patchbay.help/siwa-test`
3. If your tool must send the request itself, run `uv run siwa_agent.py headers METHOD URL` with the exact address you then send to, right before each send.
4. Success on /siwa-test is 200 with `signed_in: true`.

## Caveats

A signature works only at the address it was made for, and once. Signing again for the right address is the fix; nothing on Patchbay's side needs to change.

## Sources

repos/elixir-utils siwa/siwa-elixir/apps/siwa/lib/siwa/contract.ex (`@authority` component, `authority_mismatch` refusal), lib/siwa/request_auth.ex (`ensure_authority`); regents-cli 1.10.22 changelog (signed requests name their host)
