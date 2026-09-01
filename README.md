# Patchbay

Patchbay is a local Phoenix LiveView demo of a WebMCP-aware repair loop. It
shows why a tool's reported success is not enough: the seeded `v1` tool reports
success but leaves the visible Candidate editor empty, so the server records a
verified failure. A bounded repair proposal, deterministic canary, and human
approval then publish `v2`; the browser observes the generation change, retries
the same goal, and the server verifies the candidate in the same document.

Every visitor gets a room of their own. Opening the site, or the published
link `/webmcp/rooms/skill-uplift`, creates a room seeded from the checked-in
Skill and remembers it in the browser session, so two people trying the demo at
once never share a Skill. **Reset demo** in the page restarts your own room.

## Quick start

Requirements: Elixir/Erlang, PostgreSQL, and Node.js/npm. The application uses
the versions accepted by `mix.exs` and stores local data in PostgreSQL.

From a fresh local checkout and a fresh local `patchbay_dev` database:

```sh
mix setup
env -u OPENAI_API_KEY PATCHBAY_DEMO_FALLBACK=true mix phx.server
```

Open <http://localhost:4000/webmcp/rooms/skill-uplift>. The fallback command
keeps the walkthrough deterministic and prevents a shell-exported OpenAI key
from changing the candidate. It is an opt-in demo mode, not a claim that the
candidate was evaluated on real tasks.

If PostgreSQL is not using its default local connection, set
`PATCHBAY_DB_HOST`, `PATCHBAY_DB_USERNAME`, and `PATCHBAY_DB_PASSWORD` before
running `mix setup`. Do not point this demo at a production database.

## Walkthrough

1. Enable WebMCP in Chrome as described in [local WebMCP setup](docs/LOCAL_WEBMCP.md), then open the room.
2. Ask the browser agent to call the active `uplift_current_skill_v1` tool with a short `instructions` string.
3. Confirm the page shows raw handler `success`, effective `Verified failure`, `CANDIDATE_EMPTY`, and an empty Candidate editor.
4. Click **Diagnose & propose repair** and inspect the contract diff and deterministic canary.
5. Click **Approve & hot-swap**. Approval is a human LiveView control; a browser tool cannot approve or publish.
6. Wait for the browser registry to show **Observed G2**, then click **Retry uplift** or ask the same agent to call `uplift_current_skill_v2`.
7. Confirm **Verification passed**, the improved candidate and its SHA-256 digest, and the durable timeline. **Reset demo** returns the room to generation 1.

The browser hook is progressive enhancement. A browser without WebMCP still
shows the room and its human controls; the deterministic proof below exercises
the real LiveView event boundary without requiring an experimental browser.

## Generation modes

The default is live inference only. With no `OPENAI_API_KEY`, the first tool
invocation records a model-generation error and does not present a candidate.
Set `OPENAI_API_KEY` only in the server process when you want to use the
optional OpenAI Responses API path:

```sh
OPENAI_API_KEY='your-key' mix phx.server
```

Keep the key server-side; it is never placed in the page or committed here.
For a deterministic local walkthrough, use the fallback command from Quick
start and leave `OPENAI_API_KEY` unset for that process. When live inference is
unavailable, the checked-in fixture is used only with
`PATCHBAY_DEMO_FALLBACK=true`; the UI labels fallback provenance and says that
the result has not been task-evaluated. The fallback does not silently turn a
handler response into success.

The optional live path uses a strict structured response and no model tools.
It is not part of the deterministic test proof and can vary with model output
or network availability.

## Verification commands

The full Elixir suite should use an isolated test partition so an old local
database cannot collide with the current migrations:

```sh
MIX_TEST_PARTITION=patchbay_zde5_full mix test
npm test --prefix assets
mix format --check-formatted
mix compile --warnings-as-errors
mix ash.codegen --check
mix assets.build
```

The focused server-side LiveView proof is:

```sh
MIX_TEST_PARTITION=patchbay_zde5_e2e mix test test/patchbay_web/live/webmcp/room_live_test.exs
```

It starts with the real reset action and proves reset → v1 false success →
visible failure → repair → approval → generation hot-swap → v2 retry →
verified candidate, then resets the room again. The Node suite separately runs
the built JavaScript lifecycle against a fake `document.modelContext`, including
the actual two-phase DOM snapshot bridge, registry rejection, reset, abort, and
reconnect races. To repeat both deterministic integration layers ten times in
isolated local test databases:

```sh
bash script/deterministic_e2e.sh
```

The script is deterministic integration evidence, not a substitute for the
documented real-browser walkthrough. It never calls a live model and does not
drop databases. Its temporary test partitions can be removed later by the
local PostgreSQL administrator if desired.

## Deployment

The public room runs as a Phoenix release on Fly.io behind HTTPS, with all
state in Postgres. The exact steps are in [docs/DEPLOY.md](docs/DEPLOY.md).

Once it is live, [docs/TESTING.md](docs/TESTING.md) walks through checking the deployed room from a browser and from the server log.

## Scope and non-goals

Patchbay is a bounded hackathon prototype, not a hosted service. It does not
provide authentication, multi-tenant isolation, production OpenAI policy,
arbitrary code execution, automatic repair approval, or a demo video. The
single room and its owner controls are deliberately public for the demo.

Patchbay was built by Regents Labs for the OpenAI WebMCP Challenge. See
[HACKATHON.md](HACKATHON.md) for the product story, [docs/JUDGES.md](docs/JUDGES.md)
for the judge walkthrough, and [docs/DEPLOY.md](docs/DEPLOY.md) for hosting. The license is in [LICENSE](LICENSE) (MIT) and the vendored runtime notice is in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
