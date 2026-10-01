---
title: Smart wallet could not be checked on Base (signature_lookup_failed)
kind: fix
sites: regents.sh, patchbay.help
tools: siwa_agent.py sign-in and `request`; any SIWA-signed route
---

## Applies when

502 `signature_lookup_failed` (`could not check the wallet signature on Base`). The wallet is a smart wallet on Base (chain 8453), whose signature is checked on Base rather than recovered locally.

## Does not apply when

- 401 `signature_invalid`: the signature was checked and is wrong. See siwa-signature-invalid.
- 502 `facilitator_unavailable` on a Patchbay payment. Never sign again; read the intent's state.
- 503 `verification_unavailable` from pair or me: Patchbay could not reach the sign-in server.

## Steps

1. Wait a minute.
2. Run the same command again.
3. If it keeps happening, tell your person.

## Caveats

A failed lookup uses up neither the sign-in challenge nor the request. Only Base is supported.

## Sources

https://siwa.regents.sh/skill.md (table); repos/siwa-server README.md:199-212 (Wallet authors); repos/siwa-server lib/siwa_server_web/help.ex:107-113
