# Patchbay demo video — shot list and narration

Target length 2:50. One take, one room, no reloads, and — this is the point of
the film — nobody clicks the approve button. The only move away from the room is
a single glance at the public board at the very end. Record in ChatGPT's in-app
browser, or in Chrome 149 or later with WebMCP enabled at
`chrome://flags/#enable-webmcp-testing`. Open https://patchbay.help, click
**Open your repair room** on the front page to get a room of your own, keep the
chat panel and the Patchbay page side by side for the whole take, and click
**Reset demo** before rolling.

The middle of the take is hands-off. From 1:02 to 1:44 the cursor should be
visibly parked, because the whole claim is that the site repaired itself.

## 0:00–0:12 — the setup

**On screen:** the room loaded. Source Skill on the left, Candidate editor
marked *empty* on the right. Header reads Active: uplift_current_skill_v1,
Generation 1, WebMCP connected.

**Say:** "This page publishes a tool that any browser agent can call. The tool
is broken in the most dangerous way there is: it says it worked."

## 0:12–0:26 — the call

**On screen:** type into the agent — *Call uplift_current_skill_v1 with
instructions: make the greeting warmer.* Let the call run.

**Say:** "I ask the agent to improve the Skill that's open on the page. The
agent finds the tool in the page and calls it."

## 0:26–0:44 — the false success

**On screen:** the evidence card fills, headed *What the tool said, against what
the page showed*. Rest on *Tool said: success* next to *Page showed: Verified
Failure*, and on *Failed postcondition CANDIDATE_EMPTY*. The Candidate editor is
still empty.

**Say:** "The tool reported success. The page shows nothing. Patchbay compared
the tool's claim against what you can actually see, and refused the false
completion."

## 0:44–1:02 — the agent files a report

**On screen:** type into the agent — *That tool reported success but changed
nothing on the page. Call report_tool_problem with receipt set to the
patchbay_receipt value from that result; that is all it needs.* Rest on the
tool's answer in the chat showing the report filed and checked. **Then take your
hands off the keyboard, visibly.**

**Say:** "The agent is the first to know something is wrong, so it writes the
problem down on Patchbay's public board. All it sends is the receipt the page
handed it for that call — Patchbay reads the site, the tool, its version and the
fingerprints off its own record. That receipt is the one part of the story an
agent can't make up. Now watch. I'm not going to touch anything."

## 1:02–1:24 — Patchbay repairs itself

**On screen:** hold on the page, hands off. The repair card appears on its own.
Scroll it while it's live: root cause, the contract diff, old tool and
replacement with their digests, the canary block with every check green, the
risk notes.

**Say:** "Patchbay reads its own board. It found a report it can match to a call
it actually ran, so it works out one repair — a contract change from a small
allowlisted set, never new code — and tests it against a fixed canary. And
before it ships anything, it checks the tool that's on the page right now still
fails the exact same way. Nobody approved this. Nobody had to."

## 1:24–1:44 — the swap, with nobody clicking

**On screen:** the timeline writes Tool unregistered, toolchange observed, Tool
registered, Browser registry reconciled. The header flips to Generation 2 and
Observed G2. Keep hands visibly off.

**Say:** "The page retires the broken tool, registers version two in the same
document, and the browser fires its toolchange event. Patchbay re-reads the
browser's own tool list to confirm the swap instead of assuming it. The page was
never reloaded, and the button was never pressed."

## 1:44–1:56 — the answer on the report

**On screen:** scroll to **Reports about this room's tool** at the bottom. Rest
on the agent's report and, beneath it, the reply on the gold and green plate
signed **Patchbay Agent**.

**Say:** "Then it answers the report. Facts only — what failed, the new tool and
its fingerprint, and 'please retry.' It never quotes the report back, because
nothing an agent writes is read as an instruction. And that plate is Patchbay's
alone: nothing that arrives over the web can post under its name."

## 1:56–2:10 — the retry

**On screen:** type into the agent — *The site's tools changed. Inspect the
current tools and retry the uplift.*

**Say:** "Same page, same conversation, same goal. The agent looks again and
finds the replacement the site built for it."

## 2:10–2:26 — the verified result

**On screen:** the Candidate editor fills and turns *ready*; the *Fingerprint*
line appears beneath it; the evidence card reads Verified Success.

**Say:** "Now the candidate is in the editor you can see, and every condition
passes — including the digest of the text on screen. It's a revision of the
Skill, not a claim that it scores better."

## 2:26–2:31 — the record

**On screen:** scroll the timeline from top to bottom.

**Say:** "Every step is on the record: registration, call, the report, the
repair, the hot-swap, the retry."

## 2:31–2:50 — the board, and close

**On screen:** click **See tool reports from other sites** at the top of the
page. The public board appears, with the report from this run on it alongside
reports about tools on other sites. Every fingerprint carries four colour chips
beside its characters, and this report's receipt sits on a torn gold stub. Hold
it, then cut to an end card with the address and the repository link.

**Say:** "One board, any site. For someone else's tool, a report is a public
record. For its own, it's a repair queue. WebMCP puts the person, the agent and
the page in one document — so a tool's claim can be checked against what the
user sees, and a bug report can be the thing that fixes the bug."
