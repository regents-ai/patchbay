# Devpost submission fields

Paste-ready text for the WebMCP Challenge entry form. The longer versions of
the same answers are in [HACKATHON.md](../HACKATHON.md).

## Project name

Patchbay

## Tagline

A page that proves its agent tool lied, then repairs it with your approval.

(75 characters.)

## Why this use case is a strong fit for WebMCP

WebMCP tools run inside the page the person is looking at, next to the agent
calling them. That is the only place where "the tool said success" can be
checked against "the person can see the result" — same document, same moment.
Patchbay uses four things a page can do and a server-side tool directory
cannot: capture structured evidence for each call, including the exact contract
digest; read the shared visible state as the postcondition; retire a defective
tool and register a corrected one while the page stays open; and confirm the
change against the browser's own `toolchange` signal and tool list. The thing
being repaired is itself a browser tool. Remove WebMCP and there is no demo.

## How it creates a better user experience

A false success strands people quietly: the agent says done, the page is
unchanged, and the only route forward is a bug report and a wait. Patchbay
turns that dead end into a repair the site owner finishes in about a minute.
The page proves the failure from what is visible rather than arguing with the
model, proposes one bounded contract change, shows the before and after, runs
its checks, and then asks a person to approve. The agent picks up the corrected
tool and completes the original request. Every step stays on screen as an
ordered record.

## What people and agents can do together that was hard or impossible before

Judge a tool call by what changed on the page instead of by what the tool
reported, so success is a checked fact. Fix a broken tool while the agent
waits: the person approves, the page swaps the tool, the agent notices and
retries — no redeploy, no reload, no new conversation. Keep authority where it
belongs: the agent can read the room and check the goal through tools, but only
the human control can approve and publish, and the server never accepts a
browser claim it has not recomputed. Read the whole exchange afterwards, in
order, with digests.

## How we implemented WebMCP

The page registers three tools with the browser: `get_patchbay_room_state` and
`verify_skill_uplift_goal`, both read-only, plus one versioned working tool that
changes with the generation — `uplift_current_skill_v1`, then
`uplift_current_skill_v2`. Registration is feature-detected and each
registration owns its own abort signal, so one revision can be retired without
disturbing the others. Every call runs in two phases: capture the visible state,
run the work on the server, wait for the page to reach the expected revision,
capture the visible state again, then verify. Digests are computed in the
browser and recomputed on the server. Publishing a replacement is a server-side
action wired to the Approve & hot-swap button; the page then retires the old
tool, registers the new one, listens for `toolchange`, re-reads the browser's
tool list, and reports the observed generation and contract digest back.
Unrecognized entries and stale revisions are rejected. Elixir, Phoenix, Ash and
PostgreSQL hold the durable record; the browser holds the observed one.

## Built with

Elixir, Phoenix, Ash Framework, PostgreSQL, JavaScript, WebMCP
(`document.modelContext`), Web Crypto (SHA-256), OpenAI Responses API, Node.js,
esbuild, Tailwind CSS.

## Testing instructions

1. Open LIVE_URL_PLACEHOLDER in ChatGPT's in-app browser, or in Chrome 149 or
   later with WebMCP enabled at `chrome://flags/#enable-webmcp-testing`.
2. Ask the agent: *Call uplift_current_skill_v1 with instructions: make the
   greeting warmer.*
3. The tool reports success while the Candidate editor stays empty. The page
   records Raw handler result: success beside Effective result: Verified
   Failure, with the failed condition CANDIDATE_EMPTY.
4. Click **Diagnose & propose repair**, read the contract diff and the canary
   checks, then click **Approve & hot-swap**. The timeline shows the old tool
   retired, toolchange observed, the replacement registered, and Observed G2.
5. Ask the agent: *The site's tools changed. Inspect the current tools and
   retry the uplift.* The candidate appears in the Candidate editor,
   verification passes, and the timeline records Goal verified.
6. **Reset demo** at the bottom of the page restores the starting state.

Full walkthrough, including what to do if the agent does not re-inspect the
page's tools: [docs/JUDGES.md](JUDGES.md).

## Repository

`https://github.com/regents-ai/patchbay`

## Video

VIDEO_URL_PLACEHOLDER

## Created during the submission period

Every commit in the repository is dated 2026-09-01 or later; the first landed
2026-09-01 at 01:37 PT. The public commit history is the record.
