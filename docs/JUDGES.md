# Testing Patchbay

Patchbay is one page with an agent tool that is broken on purpose. The run
below takes about three minutes and needs no account, no key and no setup.

Open: LIVE_URL_PLACEHOLDER

The whole run happens on that one page. Nothing here asks you to navigate away,
reload, or start a new conversation.

## Pick a browser

### ChatGPT's in-app browser

Open the link inside ChatGPT's in-app browser. Page tools are switched on
there, so nothing else is needed. Keep the chat and the page both in view.

### Chrome 149 or later

1. Open `chrome://flags/#enable-webmcp-testing`.
2. Set **WebMCP** to **Enabled**.
3. Relaunch Chrome, then open the link with a browser agent that can call the
   page's tools.

More detail, including the origin-trial route, is in
[LOCAL_WEBMCP.md](LOCAL_WEBMCP.md). To run the whole thing on your own machine
instead, follow the quick start in [README.md](../README.md).

## Before you start

The top of the page should read **Active: uplift_current_skill_v1**,
**Generation 1**, and **WebMCP connected**, with **Desired G1 · Observed G1**
beside it once the browser has offered the tools. The Candidate editor on the
right is marked **empty** and says *No candidate committed*. If it is not
empty, click **Reset demo** at the bottom of the page first.

If the page says *Waiting for browser*, the browser has not offered the page's
tools yet. Give it a few seconds, then reload once.

## Step 1 — ask the agent to improve the Skill

Give the agent this prompt:

> Call uplift_current_skill_v1 with instructions: make the greeting warmer.

## Step 2 — read the failure

The Invocation evidence card fills in, headed *Raw handler ≠ visible proof*:

- **Raw handler result: success** — the tool's own answer.
- **Effective result: Verified Failure** — what the page could actually see.
- **Failed postcondition: `CANDIDATE_EMPTY`**.
- The arguments, the tool's response, and the visible state before and after.

The Candidate editor is still **empty**, and the status at the top of the page
turns to **Failed**. The agent was told it succeeded; the page disagrees, and
the page wins.

## Step 3 — ask for a repair

Click **Diagnose & propose repair**. The repair card shows:

- the root cause,
- which tool is being replaced and what replaces it, each with its digest,
- the contract diff, line by line, old value and new value,
- the deterministic canary with each check marked pass or fail,
- risk notes.

Repairs are limited to a small allowlisted set of contract changes, and the
canary has to pass before the approval buttons appear. If the card notes that
the demo's built-in repair plan was used, live inference was unavailable; the
rest of the run is unchanged.

## Step 4 — approve the swap

Click **Approve & hot-swap**. This is the only control that can publish a
replacement — no tool the agent can call is allowed to approve, publish, or
change a generation. (**Reject repair** beside it throws the proposal away.)

Watch the timeline at the bottom fill in, in order:

- **Human approval granted**
- **Tool unregistered** — the broken tool is retired
- **toolchange observed** — the browser's own signal that the page's tools
  changed
- **Tool registered** — `uplift_current_skill_v2`
- **Browser registry reconciled** — the page re-read the browser's live tool
  list and confirmed the swap

The header now reads **Active: uplift_current_skill_v2**, **Generation 2**, and
**Observed G2**.

## Step 5 — retry the original goal

Give the agent this prompt:

> The site's tools changed. Inspect the current tools and retry the uplift.

Same conversation, same page, same goal. If your agent would rather not, the
**Retry uplift** button on the page runs the identical request.

## Step 6 — read the verified result

The Candidate editor turns **ready** and holds the improved Skill with its
`sha256:` digest below it. The evidence card reports **Verified Success**, and
the timeline closes with **Verification passed** and **Goal verified**.

The candidate is a revision of the Skill, not a measured improvement. Patchbay
proves the tool did what its contract promised on the page; it makes no claim
about how the rewritten Skill performs on real tasks.

## If the agent does not pick up the new tool

Some agents cache the tool list from the start of the conversation. Send the
step 5 prompt again, word for word:

> The site's tools changed. Inspect the current tools and retry the uplift.

That asks the agent to re-read the page's tools before calling. The old tool is
no longer registered, so an agent working from a cached list will report that
it cannot find `uplift_current_skill_v1`. Click **Retry uplift** on the page to
finish the run.

## Starting over

**Reset demo**, at the bottom of the page, restores the original Skill, empties
the Candidate editor, drops the browser session evidence and returns the room
to generation 1. Anyone can run the demo again straight afterwards.

## If you cannot run a browser agent

The demo video shows the same run end to end, and the repository history holds
every commit. The product story and the answers to the challenge questions are
in [HACKATHON.md](../HACKATHON.md); the technical detail is in
[SPEC.md](../SPEC.md).
