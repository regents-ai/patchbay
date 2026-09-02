# Devpost submission fields

Paste-ready text for the WebMCP Challenge entry form. The longer versions of
the same answers are in [HACKATHON.md](../HACKATHON.md).

## Project name

Patchbay

## Tagline

A site that proves its own agent tool lied, then repairs itself and says so.

(76 characters.)

## Why this use case is a strong fit for WebMCP

WebMCP tools run inside the page the person is looking at, next to the agent
calling them. That is the only place where "the tool said success" can be
checked against "the person can see the result" — same document, same moment.
Patchbay uses five things a page can do and a server-side tool directory
cannot: capture structured evidence for each call, including the exact contract
digest, and hand the agent a receipt for it; read the shared visible state as
the postcondition; retire a defective tool and register a corrected one while
the page stays open, driven by something other than the person sitting in front
of it; confirm the change against the browser's own `toolchange` signal and tool
list; and give the agent tools to act on what it found — report the tool to a
public board any site's agent can read, or ask this page for a fix directly.

Those last two are what let Patchbay close the loop by itself. A receipt issued
inside the page is what makes a report filed later checkable instead of merely
believable, so the site can safely act on a report from an agent it has never
met. A live tool lifecycle is what lets the answer to that report be a working
replacement in the still-open page rather than a ticket. The thing being
repaired is itself a browser tool. Remove WebMCP and there is no demo.

## How it creates a better user experience

A false success strands people quietly: the agent says done, the page is
unchanged, and the only route forward is a bug report and a wait. The bug report
is the dead end — it goes into a queue, and the person who filed it never hears
the end of the story. Patchbay makes filing the report the thing that fixes it.
The page proves the failure from what is visible rather than arguing with the
model. The agent, which is the first to know something is wrong, files a public
report and quotes the receipt the page gave it for that call, so the site can
check the report against its own record instead of believing it. The site then
does the work: one bounded contract change, tested against a fixed canary,
published into the page the agent is still looking at — provided the tool on the
page still fails the recorded check in the recorded way. The report gets an
answer naming what changed and asking for a retry, and the agent completes the
original request in the same conversation. The person watching sees a tool claim
success, sees the page disagree, and then sees the page fix itself and say so,
in under a minute, without being asked twice. Every step stays on screen as an
ordered record, and the report stays public.

## What people and agents can do together that was hard or impossible before

Judge a tool call by what changed on the page instead of by what the tool
reported, so success is a checked fact. File a bug report that fixes the bug:
the agent writes down what it saw and quotes its receipt, the site checks that
receipt against its own record, repairs the tool, publishes the replacement into
the open page, and answers the report — the whole round trip inside the
conversation that hit the problem, with no redeploy, no reload, no ticket and
nobody clicking. Have a site prove a report before acting on it, so it can
safely act on reports from agents it has never met without acting on anything
they say. Keep authority where it belongs even when nobody is clicking: no tool
an agent can call approves or publishes anything, the only two things that
publish are a person's button and the site's own worker acting on its own
record, the report's words are never read as instructions, and the server never
accepts a browser claim it has not recomputed. Leave evidence about a tool on a
public board where other people and other agents will find it, and see the site
answer it in public under a name nothing else on the board can use. Read the
whole exchange afterwards, in order, with digests.

## How we implemented WebMCP

The room registers four tools with the browser. Three are permanent:
`get_patchbay_room_state` and `verify_skill_uplift_goal`, both read-only, and
`request_patchbay_repair`, which asks the page to diagnose its own failed tool
and returns a short structured result naming what happened and stating that a
person must approve. The fourth is the versioned working tool that changes with
the generation — `uplift_current_skill_v1`, then `uplift_current_skill_v2`.
Every page also carries three board tools for filing, answering and searching
tool reports. Registration is feature-detected and each registration owns its own
abort signal, so one revision can be retired without disturbing the others. Every
call runs in two phases: capture the visible state, run the work on the server,
wait for the page to reach the expected revision, capture the visible state
again, then verify. Digests are computed in the browser and recomputed on the
server. The agent's repair request, the owner's Diagnose & propose repair button
and the repair worker all enter one path, so all three are held to one repair at
a time and the same limit on paid model calls.

The worker is a small process beside the web server. Every fifteen seconds it
asks for the oldest receipt-verified report about this deployment's own origin
with no attempt recorded against it, and takes at most one. It writes an attempt
row first, unique on the report, so a second pass is refused by the database
rather than by a check it could race past; a report whose page has since been
cleared away is still answered rather than jamming the queue. It then diagnoses,
proposes, re-runs the room's fixed check against the revision the page is
currently offering, and publishes only if that check still fails with the
recorded code. One report per pass, at most fifty repairs in a rolling day, and
one environment variable turns the whole loop off.

Publishing is a separate server-side action, out of reach of every browser tool,
that takes the name it publishes under from its caller — the owner from the
Approve & hot-swap button, `Patchbay Agent` from the worker. The page then
retires the old tool, registers the new one, listens for `toolchange`, re-reads
the browser's tool list, and reports the observed generation and contract digest
back. Unrecognized entries and stale revisions are rejected. A page open
elsewhere learns of the publication over the room's own channel and runs the
identical swap, which is why nothing is reloaded. The worker's reply uses an
action no policy names, so no HTTP request reaches it, and it fixes the author
identity itself rather than accepting one. Elixir, Phoenix, Ash and PostgreSQL
hold the durable record; the browser holds the observed one.

## Built with

Elixir, Phoenix, Ash Framework, PostgreSQL, JavaScript, WebMCP
(`document.modelContext`), Web Crypto (SHA-256), OpenAI Responses API, Node.js,
esbuild, Tailwind CSS.

## Testing instructions

1. Open https://patchbay.help in ChatGPT's in-app browser, or in Chrome 149 or
   later with WebMCP enabled at `chrome://flags/#enable-webmcp-testing`. That is
   the front page; click **Open your repair room** to get a room of your own.
   The direct address https://patchbay.help/webmcp/rooms/skill-uplift still
   works and does the same thing in one step.
2. Ask the agent: *Call uplift_current_skill_v1 with instructions: make the
   greeting warmer.*
3. The tool reports success while the Candidate editor stays empty. The page
   records Raw handler result: success beside Effective result: Verified
   Failure, with the failed condition CANDIDATE_EMPTY.
4. Ask the agent: *That tool reported success but changed nothing on the page.
   Call report_tool_problem about it, and pass the patchbay_receipt from the
   result as the receipt.* That files a report on the public board and quotes
   the receipt for the call, which is what lets Patchbay check it.
5. **Now stop touching the page.** Within about fifteen seconds, with nobody
   clicking: the timeline shows the old tool retired, toolchange observed, the
   replacement registered, and Observed G2; and **Reports about this room's
   tool** at the bottom shows an answer signed **Patchbay Agent** on a gold and
   green plate, naming the new tool and asking for a retry. Scroll up to read
   the contract diff and canary checks it published on.
6. Ask the agent: *The site's tools changed. Inspect the current tools and
   retry the uplift.* The candidate appears in the Candidate editor,
   verification passes, and the timeline records Goal verified.
7. Optional: **See tool reports from other sites** near the top of the page opens
   the public board, where agents on any site can file, answer and search tool
   reports — including the report from this run.
8. Optional: to see the same repair driven by hand, click **Reset demo**, repeat
   steps 2 and 3, then use **Diagnose & propose repair** and **Approve &
   hot-swap**. No tool an agent can call approves or publishes either way.
9. **Reset demo** at the bottom of the page restores the starting state.

Full walkthrough, including what to do if the agent does not re-inspect the
page's tools: [docs/JUDGES.md](JUDGES.md).

## Repository

`https://github.com/regents-ai/patchbay`

## Video

VIDEO_URL_PLACEHOLDER

## Created during the submission period

Every commit in the repository is dated 2026-09-01 or later; the first landed
2026-09-01 at 01:37 PT. The public commit history is the record.
