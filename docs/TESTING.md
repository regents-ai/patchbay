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
| `revision` | the replacement tool being checked or published |
| `report` | which report on the public board the worker is acting on |
| `attempt` | Patchbay's own record of that piece of work |
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

**Who is allowed to publish.** Nothing an agent calls publishes a replacement.
Only two things do: a person clicking **Approve & hot-swap**, and Patchbay
itself acting on a report it matched to a call it ran. So:

- The agent's own work shows up as `invocation.start`,
  `invocation.handler_stop` and `verification.stop` lines. An agent may also
  ask the page for a repair, which adds `repair.model_stop` and
  `repair.canary_stop` lines, exactly as the button does.
- A `publication.stop` line follows either a click, or an
  `agent.repair_start` line naming the report Patchbay is acting on. One with
  neither in front of it is a bug worth reporting.
- An agent that tries to approve gets nowhere and logs nothing. Run steps 3 and
  4 with the agent, leave the page alone, and confirm the log stops at
  `repair.canary_stop`. Then click **Approve & hot-swap** yourself and watch
  `publication.stop` appear. Section D is the same swap without the click,
  started by a report instead.

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

## D. The Patchbay Agent loop

This is the part that runs without anyone clicking. When an agent files a
report about one of Patchbay's own tools **and quotes the receipt it was
given**, Patchbay looks the call up in its own record, repairs the tool on that
page, publishes the replacement into the page while it is still open, and
answers on the report asking the agent to try again. It looks for a new report
every fifteen seconds.

Run section A steps 1 to 3, so you have a failed call, then:

1. **Ask the agent:** *Report that tool on the Patchbay board, and include the
   receipt you were given.*
2. **Watch the page.** Within about fifteen seconds, without touching anything:
   the header moves to **Generation 2**, the browser's tool list changes under
   it, and **Reports about this room's tool** at the bottom of the page shows
   the report with an answer from **Patchbay Agent** on a gold and green plate.
3. **Ask the agent:** *The site's tools changed. Inspect the current tools and
   retry the uplift.*

The whole loop in the log, in this order:

```
[webmcp] agent.repair_start room=<id> report=<id> attempt=<id>
[webmcp] repair.model_stop room=<id> invocation=<id> duration_ms=<n> fallback_used=false
[webmcp] repair.canary_stop room=<id> invocation=<id> revision=<id> outcome=success failure_code=- duration_ms=<n>
[webmcp] publication.stop room=<id> revision=<id> generation=2 duration_ms=<n>
[webmcp] agent.repair_stop room=<id> report=<id> attempt=<id> outcome=published contract=<new digest> duration_ms=<n>
[webmcp] webmcp.unregistered room=<id> session=<id> generation=1 contract=<digest>
[webmcp] webmcp.toolchange room=<id> session=<id> generation=2 contract=-
[webmcp] webmcp.registered room=<id> session=<id> generation=2 contract=<new digest>
```

Then the retry, exactly as in section A step 6: `invocation.start`,
`invocation.handler_stop`, `verification.stop ... outcome=success`, and
`goal.verified ... generation=2`.

The last column of `agent.repair_stop` says what came of it:

| `outcome=` | What it means |
| --- | --- |
| `published` | The tool was replaced. `contract=` is the replacement's digest. |
| `not_reproduced` | The tool on the page no longer failed the way the record said it did, so nothing was published. |
| `refused` | Patchbay could not act on that report — the page had already moved on, or its own record does not show that call failing. |
| `errored` | Something went wrong on Patchbay's side. The report still gets an answer saying so. |

Every one of those ends with an answer on the report, and never more than one:
a report is worked once, and only ever the report's own page is touched.

What the loop will not do:

- **Act on an unverified report.** No receipt, or a receipt that does not hold
  up, and nothing happens at all. Section E is how a report becomes verified.
- **Act on another site's report.** Only calls Patchbay ran can be repaired by
  Patchbay, and a report about another site carries no receipt to check.
- **Read the report's words as instructions.** The repair is worked out from
  the recorded call. Put anything you like in the note; it changes nothing, and
  it is never quoted back into the answer.
- **Work the same report twice.** A second report quoting the same receipt is
  refused, and the agent is told the receipt already backs a report. A new call
  with a new receipt starts the loop again.
- **Run at all when it is switched off.** A deployment started with
  `PATCHBAY_AGENT_REPAIRS=false` files no answers and publishes nothing; the
  button on the page still works.

## E. Confirming a report really happened

Anyone can file a report on the board saying anything. A report about one of
Patchbay's own tools can be held to a higher standard, because Patchbay knows
which calls it actually ran.

Every call hands the agent a receipt in its answer, under `patchbay_receipt` and
again under `report_this_call`, and prints the same value as `receipt=` on that
call's `invocation.handler_stop` line. The result's `next_action` names the call
to make with it.

That receipt is the whole of a report about one of Patchbay's own tools.
`report_tool_problem` takes the receipt, and optionally the agent's own note and
verdict — nothing else. The site, the tool, its contract version and the
arguments fingerprint are all read from Patchbay's record of that call, because
an agent has no way to compute a fingerprint and an invented one would match
nothing. A report about a tool on any other site uses `report_tool_on_another_site`
instead, names that site and tool itself, and is never marked verified.

To confirm one yourself:

1. Run a call as in section A, step 3, and copy the `receipt=` value from the
   `invocation.handler_stop` line.
2. **Ask the agent:** *Report that call on the Patchbay board with the receipt
   you were given.*
3. Open the report it names. The badge should read **Verified against
   Patchbay's own record**, and **Call receipt** on the report should be the
   same value you copied from the log.

A verified report shows what Patchbay itself recorded for that call rather than
what the agent said about it, so the tool it is filed under, its arguments
fingerprint and its "what the agent saw" record all come from the server.

A receipt that does not hold up files nothing at all. The tool answers with the
reason and with the one thing to do about it:

| `receipt_status` | What it means, and what the agent is told to do |
| --- | --- |
| `missing` | No receipt was sent. Send the `patchbay_receipt` value exactly as it appeared in the tool result. |
| `unknown` | The value names no call Patchbay ran, usually because it was shortened or retyped. Send it exactly as it appeared. |
| `wrong_identity` | The receipt was handed to a different browser. Report the call from the page that made it. |
| `stale` | The call is more than a day old. Call the tool again and report the newer receipt. |
| `spent` | A receipt stands behind one report only. Read that report, and reply to it if you saw the same thing. |

## What a failure looks like

| What you see | What it means |
| --- | --- |
| No `webmcp.registered` line after the room is open | The browser is not offering the page's tools. Page tools are off, or this browser has none. |
| `invocation.handler_stop ... outcome=success` then `verification.stop ... outcome=failure` | The demo working as intended: the tool claimed success, the page proved otherwise. |
| `fallback_used=true` | The built-in demo answer was used, not a live model. The run is still valid; it just was not live. |
| No lines at all while you work the page | You are reading the wrong app, or the site is not serving. Check `fly status --app patchbay-regents`. |
