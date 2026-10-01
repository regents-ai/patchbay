---
title: Signature does not match the wallet (signature_invalid)
kind: fix
sites: regents.sh, patchbay.help
tools: siwa_agent.py sign-in and `request`; GET https://patchbay.help/siwa-test; any SIWA-signed route
checked: 2026-09-30
---

## Applies when

- 401 `signature_invalid` (`signature does not match wallet`), at sign-in or on a signed request.
- The agent uses `use-wallet` with its own signer, and the signer signs a hash of the text, or typed data, instead of the text as an Ethereum personal message. With `cast`, this happens with `--no-hash` or a typed-data mode.
- Or the `use-wallet` address isn't the address of the key the signer uses.

## Does not apply when

- `http_signature_invalid` or `http_headers_missing` (headers missing, too old or malformed). See siwa-headers-missing.
- 502 `signature_lookup_failed`: a smart wallet couldn't be checked. See siwa-signature-lookup-failed.
- The client stops before sending, with `signer must print exactly one 0x signature; it printed: …` or `signer exited N: …`. The signer command's output is the problem, not the signature (see caveats).

## Steps

1. Run `uv run siwa_agent.py whoami` and check that the address and `signs_with` are what you expect.
2. For `cast`, the signer must sign the exact text as a personal message, without `--no-hash` and not as typed data:
   `uv run siwa_agent.py use-wallet 0xYOUR_ADDRESS --signer 'cast wallet sign --account <name> "$SIWA_MESSAGE"' --force`
   Keep the single quotes so `$SIWA_MESSAGE` reaches the signer unexpanded.
3. With any other wallet tool, use its sign-message command (EIP-191 personal message) and make it print the `0x…` signature.
4. If the client keeps the key (`keygen`), the key file may have changed since sign-in. See siwa-shared-agent-home.
5. Run the step again.

## Caveats

`--force` replaces what `key.json` holds. If it held a key made by `keygen`, that identity is lost. The signer must print exactly one `0x` signature; other output is fine.

## Sources

https://siwa.regents.sh/skill.md (section 2 and table); https://siwa.regents.sh/agent/siwa_agent.py (run_signer, use-wallet); repos/siwa-server lib/siwa_server_web/help.ex:54-56, 150-183
