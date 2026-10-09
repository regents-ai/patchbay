# Patchbay signed identity commands

These source descriptions must be imported into the shared Regents CLI before
claiming an installed version supports them. Other commands are described in
`commands.json` and the public agent guide.

## regents patchbay agents whoami

- **Purpose:** verify the existing agent's identity and pairing without awarding Points.
- **Authority:** fresh exact-request SIWA proof; works before pairing and grants no product access.
- **Route:** `GET /api/agents/v1/whoami` → `agentWhoami`.
- **Inputs:** none.
- **Effect:** read only; no pairing, wallet authority or spending grant changes.

This replaces the singular `agent whoami` description, without an alias. Use the
shared CLI's non-rewarding `auth status --site patchbay` to check signer and pairing
readiness when available. No signer means blocked, not unpaired.

## regents patchbay agents pair

- **Purpose:** redeem the owner's single-use code for the existing agent identity after owner approval.
- **Authority:** fresh exact-request SIWA proof from that agent's existing signer.
- **Route:** `POST /api/agents/v1/pair` → `pairSharedAgent`, the existing shared route.
- **Inputs:** private stdin JSON containing required strings `code`, `name` and `harness`.
- **Effect:** creates the current pairing episode; creates no key and enables no spending grant.
- **Answer:** 201 with the existing paired-agent envelope.
- **Refusals:** 400 invalid, used or expired code or unsupported input; 401 rejected proof; 409 account agent limit; 429 rate limit; 503 verification unavailable.

Keep the code out of command arguments, shell history and saved reports. The server
validates the display name and supported harness, including `codex` and `dots`.
Probe `agents whoami` first, ask the owner to approve pairing only when unpaired,
redeem once, then probe again with fresh proof. Follow the SIWA guide for signer
setup. A local fixture check does not establish real native signing acceptance.
