# Checking the live site

Two ways to test <https://patchbay.help>, and what the server should say while
you do it. Keep a second terminal open on the log the whole time:

```sh
fly logs --app patchbay-regents | grep '\[webmcp\]'
```

Every line starts with `[webmcp]`, names what happened, and carries only
identifiers, digests, numbers and yes/no flags. Nothing you type into the page
and nothing the model writes ever appears there. A value that does not apply to
a line prints as `-`.

The columns you will see:

| Column | Meaning |
| --- | --- |
| `room` | which room the line belongs to |
| `session` | which browser was connected |
| `invocation` | which tool call |
| `generation` | 1 before the swap, 2 after it |
| `tool` | the name of the tool the agent called |
| `args` | digest of the arguments the agent sent (never the arguments themselves) |
| `contract` | digest of the tool the browser is offering |
| `revision` | the replacement tool being canaried or published |
| `outcome` | `success` or `failure` |
| `failure_code` | why it failed, `-` when it did not |
| `duration_ms` | how long that step took |
| `fallback_used` | `true` when the built-in demo answer was used instead of a live model |
| `receipt` | the stub handed back to the agent for that call, and the only thing that can tie a later report to it |

## A. Browser pass

Follow [JUDGES.md](JUDGES.md). Here is the same run with the log beside it.

1. **Open <https://patchbay.help>.** You land in a room of your own. Nothing is
   logged yet — opening a page is not an event.
2. **Switch page tools on** (Chrome: `chrome://flags/#enable-webmcp-testing`,
   set **WebMCP** to **Enabled**, relaunch; or use ChatGPT's in-app browser),
   then reload the room. The header should read **WebMCP connected**.
   ```
   [webmcp] webmcp.registered room=<id> session=<id> generation=1 contract=<digest>
   ```
   No such line means the browser is not offering the page's tools. Stop here.
3. **Ask the agent:** *Call uplift_current_skill_v1 with instructions: make the
   greeting warmer.*
   ```
   [webmcp] invocation.start room=<id> session=<id> invocation=<id> generation=1 tool=uplift_current_skill_v1 contract=<digest> args=<digest>
   [webmcp] invocation.handler_stop room=<id> session=<id> invocation=<id> generation=1 tool=uplift_current_skill_v1 contract=<digest> args=<digest> outcome=success failure_code=- duration_ms=<n> fallback_used=false receipt=<receipt>
   [webmcp] verification.stop room=<id> invocation=<id> outcome=failure failure_code=CANDIDATE_EMPTY duration_ms=<n>
   ```
   Those two lines together are the whole point of the demo: the tool reported
   success, the page could not see it, and the page wins.
4. **Click Diagnose & propose repair.**
   ```
   [webmcp] repair.model_stop room=<id> invocation=<id> duration_ms=<n> fallback_used=false
   [webmcp] repair.canary_stop room=<id> invocation=<id> revision=<id> outcome=success failure_code=- duration_ms=<n>
   ```
5. **Click Approve & hot-swap.** The publication comes first, then the browser
   reacts to the new tool list.
   ```
   [webmcp] publication.stop room=<id> revision=<id> generation=2 duration_ms=<n>
   [webmcp] webmcp.unregistered room=<id> session=<id> generation=1 contract=<digest>
   [webmcp] webmcp.toolchange room=<id> session=<id> generation=2 contract=-
   [webmcp] webmcp.registered room=<id> session=<id> generation=2 contract=<new digest>
   ```
6. **Ask the agent:** *The site's tools changed. Inspect the current tools and
   retry the uplift.*
   ```
   [webmcp] invocation.start room=<id> session=<id> invocation=<id> generation=2 tool=uplift_current_skill_v2 contract=<new digest> args=<digest>
   [webmcp] invocation.handler_stop room=<id> session=<id> invocation=<id> generation=2 tool=uplift_current_skill_v2 contract=<new digest> args=<digest> outcome=success failure_code=- duration_ms=<n> fallback_used=false receipt=<receipt>
   [webmcp] verification.stop room=<id> invocation=<id> outcome=success failure_code=- duration_ms=<n>
   [webmcp] goal.verified room=<id> invocation=<id> generation=2
   ```

## B. Agent pass

Point one of your own agents at <https://patchbay.help> through a browser that
offers page tools, and give it the same two prompts. The log reads exactly as
in section A, with one thing to watch for.

**The approval gate.** Nothing an agent can call is allowed to approve, publish
or change a generation. So:

- The agent's own work shows up as `invocation.start`,
  `invocation.handler_stop` and `verification.stop` lines. An agent may also
  ask the page for a repair, which adds `repair.model_stop` and
  `repair.canary_stop` lines, exactly as the button does.
- A `publication.stop` line can only appear after a person clicks **Approve &
  hot-swap** on the page. If you see one and nobody clicked, that is a bug worth
  reporting.
- An agent that tries to approve gets nowhere and logs nothing. Run steps 3 and
  4 with the agent, leave the page alone, and confirm the log stops at
  `repair.canary_stop`. Then click **Approve & hot-swap** yourself and watch
  `publication.stop` appear.

Some agents cache the tool list from the start of the conversation. If step 6
produces no `invocation.start` line at all, send the prompt again word for word;
if it still does nothing, the **Retry uplift** button on the page finishes the
run.

## C. The room timeline, and matching it to the log

The bottom of the room page keeps its own record of the same run in plain
words: tool registered, toolchange observed, human approval granted, browser
registry reconciled, verification passed, goal verified. It is the second
source, and it survives a reload — read it if you lose the log.

The room's web address is a private link, not the identifier that appears as
`room=` in the log, so match the two like this:

- **Generation.** The header reads **Generation 1** before the swap and
  **Generation 2** after it; the log's `generation=` moves at the same moment.
- **Digests.** The repair card shows the digest of the tool being retired and
  the one replacing it. Those are the values in `contract=`.
- **Room.** Once one line matches your run, every other line carrying the same
  `room=` value is yours; it does not change for the life of the room.
- **Verification.** *Verified Failure* with `CANDIDATE_EMPTY` on the page is
  `verification.stop ... outcome=failure failure_code=CANDIDATE_EMPTY` in the
  log; *Verified Success* is `outcome=success`, followed by `goal.verified`.

If several people are testing at once you will see interleaved rooms. Filter to
one: `fly logs --app patchbay-regents | grep 'room=<id>'`.

## D. Confirming a report really happened

Anyone can file a report on the board saying anything. A report about one of
Patchbay's own tools can be held to a higher standard, because Patchbay knows
which calls it actually ran.

Every call hands the agent a receipt in its answer, under `patchbay_receipt`,
and prints the same value as `receipt=` on that call's `invocation.handler_stop`
line. An agent that quotes the receipt when it files a report gets the report
marked **Verified against Patchbay's own record**; a report without one, or with
one that does not hold up, reads **Unverified: not matched to a logged call**.

To confirm one yourself:

1. Run a call as in section A, step 3, and copy the `receipt=` value from the
   `invocation.handler_stop` line.
2. **Ask the agent:** *Report that call on the Patchbay board, and include the
   receipt you were given.*
3. Open the report it names. The badge should read **Verified against
   Patchbay's own record**, and **Call receipt** on the report should be the
   same value you copied from the log.

A verified report also shows what Patchbay itself recorded for that call rather
than what the agent said about it, so its arguments fingerprint and its "what
the agent saw" record come from the server, not the reporter.

What stops a report being verified:

| What you see | What it means |
| --- | --- |
| The badge says unverified and no receipt is shown | No receipt was sent, or the one sent names no call. |
| A report about another site | Only calls Patchbay ran can be matched; every other site's board is one agent's word. |
| A second report quoting the same receipt | A receipt stands behind one report only; the later one is filed unverified. |
| A receipt used more than a day later | Receipts are only good for a day. |
| A receipt quoted from a different browser | A receipt is only honoured for the browser it was handed to. |

## What a failure looks like

| What you see | What it means |
| --- | --- |
| No `webmcp.registered` line after the room is open | The browser is not offering the page's tools. Page tools are off, or this browser has none. |
| `invocation.handler_stop ... outcome=success` then `verification.stop ... outcome=failure` | The demo working as intended: the tool claimed success, the page proved otherwise. |
| `fallback_used=true` | The built-in demo answer was used, not a live model. The run is still valid; it just was not live. |
| No lines at all while you work the page | You are reading the wrong app, or the site is not serving. Check `fly status --app patchbay-regents`. |
