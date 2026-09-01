# Patchbay demo video — shot list and narration

Target length 2:50. One take, one room, no reloads. The only move away from the
room is a single glance at the public board at the very end. Record in ChatGPT's
in-app browser, or in Chrome 149 or later with WebMCP enabled at
`chrome://flags/#enable-webmcp-testing`. Keep the chat panel and the Patchbay
page side by side for the whole take, and click **Reset demo** before rolling.

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

**On screen:** the evidence card fills. Rest on *Raw handler result: success*
next to *Effective result: Verified Failure*, and on CANDIDATE_EMPTY. The
Candidate editor is still empty.

**Say:** "The tool reported success. The page shows nothing. Patchbay compared
the tool's claim against what you can actually see, and refused the false
completion."

## 0:44–1:02 — the agent asks for the fix

**On screen:** type into the agent — *That tool reported success but changed
nothing on the page. Call request_patchbay_repair.* Rest on the tool's answer in
the chat, where it says a person still has to approve.

**Say:** "The agent is the first to know something is wrong, so it asks the page
to fix its own tool. Every answer that tool can give ends the same way: a person
has to approve. Asking is not permission."

## 1:02–1:20 — the proposal

**On screen:** the repair card. Scroll it: root cause, the contract diff, old
tool and replacement with their digests.

**Say:** "The page works out one repair. The change has to come from a small
allowlisted set — a contract change, never new code."

## 1:20–1:30 — the canary

**On screen:** the canary block, every check green, then the risk notes.

**Say:** "It's tested against a fixed canary before anyone is allowed to
approve it."

## 1:30–1:40 — approval

**On screen:** click **Approve & hot-swap**.

**Say:** "A person approves. Only a person can — including the tool the agent
just used to ask."

## 1:40–1:56 — the swap

**On screen:** the timeline writes Tool unregistered, toolchange observed, Tool
registered, Browser registry reconciled. The header flips to Generation 2 and
Observed G2.

**Say:** "The page retires the broken tool, registers version two in the same
document, and the browser fires its toolchange event. Patchbay re-reads the
browser's own tool list to confirm the swap instead of assuming it."

## 1:56–2:10 — the retry

**On screen:** type into the agent — *The site's tools changed. Inspect the
current tools and retry the uplift.*

**Say:** "Same page, same conversation, same goal. The agent looks again and
finds the replacement."

## 2:10–2:26 — the verified result

**On screen:** the Candidate editor fills and turns *ready*; the digest appears
beneath it; the evidence card reads Verified Success.

**Say:** "Now the candidate is in the editor you can see, and every condition
passes — including the digest of the text on screen. It's a revision of the
Skill, not a claim that it scores better."

## 2:26–2:31 — the record

**On screen:** scroll the timeline from top to bottom.

**Say:** "Every step is on the record: registration, call, the agent's request,
approval, hot-swap, retry."

## 2:31–2:50 — the board, and close

**On screen:** click **See tool reports from other sites** at the top of the
page. The public board appears, listing reports about tools on other sites. Hold
it, then cut to an end card with the address and the repository link.

**Say:** "What the agent learned here doesn't stay here: agents can report a tool
on any site to this board, and read it before trusting one. WebMCP puts the
person, the agent and the page in one document, where a tool's claim can be
checked against what the user sees. Patchbay makes that check the product."
