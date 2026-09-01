# Patchbay

Patchbay is a website that catches its own broken agent tool, proves the
failure from what you can see on the page, and lets the site owner approve a
fix while the agent waits in the same conversation.

Built for the WebMCP Challenge.

- Try it: LIVE_URL_PLACEHOLDER
- Step-by-step testing: [docs/JUDGES.md](docs/JUDGES.md)
- Run it locally: [README.md](README.md)

## The problem

A tool can tell an agent "success" and change nothing the person can see. The
agent says the job is done, the page is unchanged, and nobody notices until
the user does. Everything built on top of that answer — retries, repairs,
automatic tool updates — inherits the lie.

## What Patchbay does

The demo is one page, the Skill Uplift Studio. It holds a Skill document you
can edit on the left and a read-only Candidate editor on the right. The goal
printed at the top is the whole test: *place an improved candidate in the
visible Candidate editor.*

The page publishes an agent tool called `uplift_current_skill_v1`. That tool is
broken on purpose: it drafts a candidate and returns success without ever
writing the Candidate editor.

1. An agent calls the tool. The page records the tool's own answer, **Raw
   handler result: success**, next to what it can actually see, **Effective
   result: Verified Failure**, with the failed condition `CANDIDATE_EMPTY`.
2. The owner clicks **Diagnose & propose repair**. The proposal names the root
   cause, shows the exact change to the tool's contract, names the tool being
   replaced and its replacement with their digests, and runs a fixed set of
   checks against a canary before anyone can approve it.
3. The owner clicks **Approve & hot-swap**. Only this control can publish a
   replacement. No agent tool can approve, publish, or change a generation.
4. The page retires the broken tool, registers `uplift_current_skill_v2` in the
   same document, and confirms the swap against the browser's live tool list.
   The timeline records **Tool unregistered**, **toolchange observed**, **Tool
   registered**, and **Browser registry reconciled**, and the header moves from
   Observed G1 to **Observed G2**.
5. The same agent, in the same conversation and without leaving the page,
   retries the same goal. The candidate appears in the Candidate editor with
   its digest, the page reports **Verification passed**, and the timeline ends
   with **Goal verified**.

**Reset demo** puts the room back to its starting state so the next person can
run it from the top.

## Why this use case is a strong fit for WebMCP

WebMCP tools live inside the page the person is looking at, next to the agent
that calls them. That is the one place where "the tool said success" can be
checked against "the person can see the result" — the same document, the same
moment, no screenshots and no guessing.

Patchbay leans on four things WebMCP gives a page and a server-side tool
directory cannot:

- Structured evidence for each call: tool name, exact contract digest,
  arguments, and result.
- Shared visible state, so the postcondition is what the human can read.
- A live tool lifecycle: a defective tool can be retired and a corrected
  revision registered while the page stays open.
- The browser's own `toolchange` signal and tool list, so the page can confirm
  the swap instead of assuming it.

The tool being repaired is itself a browser tool. WebMCP is not decoration
here; take it away and there is no demo.

## How it creates a better user experience

Today a false success strands the person quietly. The agent reports done, the
page shows nothing, and the only route forward is a bug report and a wait for
the site to ship a fix.

Patchbay turns that dead end into a repair the owner can finish in about a
minute. The page proves the failure from visible state instead of arguing with
the model. It proposes one bounded change and shows the before and after. It
runs its checks first, then asks a person to approve. The agent picks up the
new tool and finishes the original request. Every step stays on screen as an
ordered record the owner can read afterwards.

## What people and agents can do together that was hard or impossible before

- Judge a tool call by what changed on the page rather than by what the tool
  reported. Success becomes a checked fact.
- Fix a broken tool while the agent waits. The person approves, the page swaps
  the tool, the agent notices and retries — no redeploy, no reload, no new
  conversation.
- Keep the authority in the right hands. The agent can read the room and check
  the goal through tools; only the human control can approve and publish. The
  server never treats a browser claim as true without recomputing it.
- Read the whole exchange afterwards: registration, call, verification,
  diagnosis, approval, swap, retry, all in order with digests.

## How we implemented WebMCP

The page registers three tools with the browser: `get_patchbay_room_state` and
`verify_skill_uplift_goal`, which are read-only, and one versioned working tool
that changes with the generation — `uplift_current_skill_v1`, then
`uplift_current_skill_v2`. Registration is feature-detected, and each
registration owns its own abort signal so one revision can be retired without
disturbing the others.

Every call runs in two phases. The page captures the visible state, sends the
work to the server, waits for the page to reach the expected revision,
captures the visible state again, and only then verifies. Digests of the source
and candidate text are computed in the browser and recomputed on the server.

Publication is a server-side action wired to the **Approve & hot-swap**
button. When it runs, the page retires the old tool, registers the replacement
under a new name, listens for the browser's `toolchange` event, re-reads the
browser's tool list, and reports the observed generation and the exact contract
digest back to the server. Entries the server does not recognize, and stale
revisions, are rejected.

Elixir, Phoenix, Ash and PostgreSQL hold the durable record; the browser holds
the observed one. Where they disagree, the page shows both and trusts neither
on its own.

## Provenance

Patchbay was created during the submission period. The first commit landed on
2026-09-01 at 01:37 PT, and every commit in this repository is dated 2026-09-01
or later. The public commit history in the repository is the record.

## Boundaries

Patchbay is a hackathon prototype. There are no accounts and no sign-in: the
demo room is single and public, and anyone who opens it can drive it. Tenant
isolation, production deployment hardening, arbitrary code execution and
automatic approval without a person are all outside the demo. Repairs are
limited to a small allowlisted set of contract changes; the system cannot
write new code for itself.

The rewritten Skill is a candidate revision, not a measured improvement.
Patchbay verifies that the page's tool did what its contract promised. It makes
no claim that the rewritten Skill performs better on real tasks, and the repair
card's risk notes say the same on screen.
