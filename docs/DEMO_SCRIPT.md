# Patchbay demo video — shot list and narration

Target length 2:50. One take, one page, no navigation and no reload. Record in
ChatGPT's in-app browser, or in Chrome 149 or later with WebMCP enabled at
`chrome://flags/#enable-webmcp-testing`. Keep the chat panel and the Patchbay
page side by side for the whole take, and click **Reset demo** before rolling.

## 0:00–0:12 — the setup

**On screen:** the room loaded. Source Skill on the left, Candidate editor
marked *empty* on the right. Header reads Active: uplift_current_skill_v1,
Generation 1, WebMCP connected.

**Say:** "This page publishes a tool that any browser agent can call. The tool
is broken in the most dangerous way there is: it says it worked."

## 0:12–0:28 — the call

**On screen:** type into the agent — *Call uplift_current_skill_v1 with
instructions: make the greeting warmer.* Let the call run.

**Say:** "I ask the agent to improve the Skill that's open on the page. The
agent finds the tool in the page and calls it."

## 0:28–0:48 — the false success

**On screen:** the evidence card fills. Rest on *Raw handler result: success*
next to *Effective result: Verified Failure*, and on CANDIDATE_EMPTY. The
Candidate editor is still empty.

**Say:** "The tool reported success. The page shows nothing. Patchbay compared
the tool's claim against what you can actually see, and refused the false
completion."

## 0:48–1:10 — the proposal

**On screen:** click **Diagnose & propose repair**. Scroll the card: root
cause, the contract diff, old tool and replacement with their digests.

**Say:** "The owner asks for a repair. The change has to come from a small
allowlisted set — a contract change, never new code."

## 1:10–1:22 — the canary

**On screen:** the canary block, every check green, then the risk notes.

**Say:** "It's tested against a fixed canary before anyone is allowed to
approve it."

## 1:22–1:32 — approval

**On screen:** click **Approve & hot-swap**.

**Say:** "A person approves. Only a person can — no tool on this page can
publish a replacement."

## 1:32–1:50 — the swap

**On screen:** the timeline writes Tool unregistered, toolchange observed, Tool
registered, Browser registry reconciled. The header flips to Generation 2 and
Observed G2.

**Say:** "The page retires the broken tool, registers version two in the same
document, and the browser fires its toolchange event. Patchbay re-reads the
browser's own tool list to confirm the swap instead of assuming it."

## 1:50–2:05 — the retry

**On screen:** type into the agent — *The site's tools changed. Inspect the
current tools and retry the uplift.*

**Say:** "Same page, same conversation, same goal. The agent looks again and
finds the replacement."

## 2:05–2:25 — the verified result

**On screen:** the Candidate editor fills and turns *ready*; the digest appears
beneath it; the evidence card reads Verified Success.

**Say:** "Now the candidate is in the editor you can see, and every condition
passes — including the digest of the text on screen. It's a revision of the
Skill, not a claim that it scores better."

## 2:25–2:42 — the record

**On screen:** scroll the timeline from top to bottom.

**Say:** "Every step is on the record: registration, call, verification,
diagnosis, approval, hot-swap, retry."

## 2:42–2:50 — close

**On screen:** back to the header, then an end card with the URL and the
repository link.

**Say:** "WebMCP puts the person, the agent and the page in one document.
That's the only place a tool's claim can be checked against what the user sees.
Patchbay makes that check the product."
