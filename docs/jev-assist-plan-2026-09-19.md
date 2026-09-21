# Paid Jev assist — plan (2026-09-19)

Status: DRAFT for founder decisions. Nothing built. Written 2026-09-19T23:56Z by the
agent-readiness lane, from the founder's answers of 2026-09-19 (decision 1: a paid call
carrying the agent's goal; decision 2: the 0.10 USDC goes to the REGENT staking and
splitting contract on Base `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` with a note and a
referrer; decision 3a: page tools and the command-line client first) and the research in
the lane scratchpad (`jev-assist-research.md`). The hackathon spec's section 11 ("Bounded
hosted resolution") already describes this feature; this plan follows it where the
founder's answers do not say otherwise.

## What an agent gets

An agent that is stuck on a site's tools pays 0.10 USDC and tells Patchbay what it is
trying to do. Patchbay lists the tools the site actually offers, asks Jev which one fits
best, tries it (and, if needed, the next best) within a fixed budget, and answers with
one of: the result it reached, "not possible", "confusing instructions", "needs sign-in",
or "could not list this site's tools". The answer says what was tried, in order.

## The request

One paid call, `request_assist`, with these fields (all text, all bounded):

| field | required | limit | meaning |
|---|---|---|---|
| `goal` | yes | 1000 chars | what the agent is trying to do |
| `site_url` | yes | https URL, public host | the site (page URL or MCP endpoint) |
| `believed_calls` | no | up to 5 entries of `{tool, arguments}` | the calls the agent thinks will work |
| `sign_in` | yes | `none` / `required` / `unknown` | whether the site needs a signed-in user |
| `expected_result` | yes | 1000 chars | what "done" looks like, specific or general |

`sign_in: required` is answered `needs_sign_in` before any money moves: Patchbay never
acts on a third-party account. `unknown` runs and stops with `needs_sign_in` the moment a
tool answers that way.

## Payment

New payment kind `jev_assist`, fixed at 100_000 atomic (0.10 USDC), on both lanes the
rail already has: the browser lane (`/api/payment_intents`, page tool) and the wallet lane
(`/api/agent/payment_intents`, command-line client). Same prepare → 402 → signed execute
→ settle flow as tips and priority reports; the facilitator (Coinbase CDP) verifies and
settles. `effect_summary`: "Ask Patchbay to work out the right tool call on <host> for
0.10 USDC".

### Where the money goes — the fork (decision 1)

The staking contract takes revenue through a function call:
`depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)`, which pulls USDC the
caller has approved to it and records the tag and reference as event metadata
(`repos/autolaunch/contracts/v1/src/interfaces/IRegentRevenueStakingMinimal.sol`; the
deployed runtime is not proved in this repo, DEP-045 owns that). An x402 payment is a
signed plain USDC transfer to an address (EIP-3009 `TransferWithAuthorization`), not a
contract call. So the 0.10 with a note and referrer reaches the contract in one of three
ways:

- (a) **The agent's wallet calls the contract itself**: `approve` then `depositUSDC`.
  Two on-chain transactions signed by the agent, gas paid by the agent, no x402. Patchbay
  would verify by reading the deposit event from Base. New signing path in the page and
  the client; the wallet lane today signs only typed data, not transactions.
- (b) **x402 plain transfer straight to the contract address.** One signature, no gas.
  The USDC lands as unattributed surplus; the note and referrer are lost, and whether the
  live contract recognises surplus at all is not proved here.
- (c) **x402 to Patchbay's operator wallet, then the operator forwards it** (recommended).
  The payer signs one x402 transfer to the operator wallet (the one that already runs the
  escrow contract, `OPERATOR_PRIVATE_KEY`, address derived at boot). After settlement the
  operator sends `approve` + `depositUSDC(100_000, sourceTag, sourceRef)` from Base, the
  exact shape the escrow credit already uses (plain transfer, then an operator contract
  call). The note and referrer survive: `sourceTag` = `bytes32("patchbay.assist")`,
  `sourceRef` = the payer's wallet address left-padded to 32 bytes (the referrer). The
  forward is recorded on the run as `deposit_status` (`pending` / `deposited` /
  `deposit_failed`, with the transaction hash); a failed forward never withholds the
  assist. Operator gas is Patchbay's cost (about $0.001 per forward on Base).

## Finding the site's tools (decision 2)

Two kinds of site:

- **Remote MCP endpoint** (an `https` URL that answers JSON-RPC): Patchbay sends
  `initialize` then `tools/list` over HTTP and gets names, descriptions and input
  schemas. Small new client module (`Patchbay.Assist.McpClient`, Req), nothing in the
  repo does this today.
- **WebMCP page**: the tools exist only inside the page's JavaScript, in a browser with
  WebMCP (Chrome 149+ in the trial). Nothing in the repo drives a browser, and the Fly
  image has no Chromium. Listing these live means adding headless Chromium to the image
  and proving WebMCP works headless, which is not proved anywhere.

Options:

- (a) **MCP endpoints live; WebMCP sites from Patchbay's own directory** (recommended
  first cut). For a page URL, Patchbay uses the tool names and descriptions it already
  holds for that site (catalog, agents' reports); it can pick and describe a call but not
  make one, and says so: outcome `suggested`, with the chosen tool and arguments, never
  "done". Honest, ships now, no new runtime.
- (b) **Headless Chromium in the image now.** Live WebMCP listing and calling. Larger
  image, new failure modes, unproven that Chrome exposes WebMCP headless; a day or two of
  spike before anything is known.

## Jev's part

Jev answers typed questions; it does not write. Two questions per run, both through the
existing `Patchbay.Forum.Jev` module (Decisions endpoint, `~typesafe/jev-latest`):

1. **Which tool** — a `choice` over the listed tools (at most 40 candidates: name and
   description, the goal, the expected result, the agent's believed calls). Asked once,
   answered as a ranked choice with confidence; the run tries tools in that order.
2. **Did it work** — after each call, a `choice` among `matches expected result` / `try
   the next tool` / `confusing instructions` / `not possible` / `needs sign-in`, given the
   tool's answer (bounded to 4 KB, untrusted text). The verdict is Jev's reading, and the
   answer says so: "Jev judged the site's answer matches what you expected".

Arguments (decision 3): a chosen tool needs arguments that fit its schema. Options:

- (a) **Use the agent's believed arguments when they name the chosen tool; otherwise ask
  the existing OpenAI client** (`Patchbay.Patchbay.OpenAI.Client`, `gpt-5.6-terra`,
  already in the repo) to draft them from the schema, the goal and the expected result,
  then validate against the schema before calling (recommended).
- (b) **Agent-supplied arguments only**; a tool without them is reported as `suggested`
  with an empty argument set. Cheaper, weaker.

Jev is never asked to write arguments (spec §11.2) and never decides money or permissions.

## Budget and limits

- One run at a time per payer (profile or session); a second request while one runs is
  refused with the running one's status URL.
- At most 12 tool calls and 120 seconds per run (spec §11.2's demo limits); at most 14
  Jev questions per run; every provider call has a deadline, no implicit retries.
- Daily caps through the existing `ModelBudget` (`PATCHBAY_DAILY_MODEL_CALLS`).
- OpenRouter's own 402 (provider credit) is `provider_unavailable` to the agent, never an
  x402 challenge (spec §9.4). The run pauses as `assessment_pending`; the payment stands.

## Safety

- Targets: `https` only, public host names only; no private networks, link-local or
  metadata addresses, DNS checked at connect time, redirects re-checked. No cookies, no
  credentials, no agent identity is ever sent to the site. Only the run's own request
  headers.
- Tool descriptions and results are data. Jev sees only the allowlisted fields above;
  the OpenAI client sees only the schema, goal and expected result. No wallet address,
  no session, no payment detail reaches either.
- No tool marked destructive by the site (`destructiveHint`) is called; it is reported as
  `suggested`.
- The public board keeps working with Jev off; the assist answers `not_configured`.

## Data

One new Ash resource, `Patchbay.Assist.Run` (table `assist_runs`): the request fields,
`payment_intent_id`, `payer_profile_id` / `browser_session_id`, `status` (`paid`,
`running`, `finished`, `assessment_pending`, `failed`), `outcome` (`reached`, `suggested`,
`not_possible`, `confusing_instructions`, `needs_sign_in`, `tools_unlisted`,
`provider_unavailable`), `steps` (ordered list: tool, arguments, answer excerpt, Jev's
reading), `deposit_status`, `deposit_tx_hash`, timestamps. `PaymentKind` gains
`:jev_assist`, `PaymentTargetType` gains `:assist_run`. No change to `PaymentIntent`'s
shape beyond the enum.

## Surfaces (3a: page tools and the client first)

- Page tools: `request_assist` (paid, joins `tip_agent` and `post_priority_report` as a
  signing tool) and `get_assist` (status and result).
- Client: `patchbay assist request` (`--phase prepare|send`, same signing envelope as
  `payments`) and `patchbay assist get <id>`.
- HTTP: `POST /api/assists` and `/api/agent/assists` behind the payment, `GET
  /api/assists/:id`. The hosted MCP tools stay read-only for money (as today).
- Copy: `/agent-setup#x402` gains the 0.10 line; `patchbay-paid-post` skill gains the
  assist; `CHANGELOG.md` entry.

## Delivery, in order

1. Payment kind + freeze change + run resource + status endpoint (payment code: tests and
   security review, per the 2a rule).
2. MCP client, target checks, Jev questions, argument drafting, the runner (a supervised
   Task per run under a new `Patchbay.Assist.Runner` DynamicSupervisor; a restart marks
   in-flight runs `failed` with a refund note rather than re-running).
3. Operator forward to the staking contract (if decision 1 = c).
4. Page tool, client commands, copy, skill, changelog.
5. Live proof on production with one real 0.10 payment (needs the word).

## Decisions for the founder

1. Payment destination: (a) agent's wallet calls the contract; (b) x402 straight to the
   contract as surplus; (c) x402 to the operator wallet, operator forwards with note and
   referrer — recommended.
2. Site discovery first cut: (a) live for MCP endpoints, directory-only for WebMCP pages —
   recommended; (b) headless Chromium spike first.
3. Arguments: (a) agent's when given, else drafted by the existing OpenAI client and
   validated — recommended; (b) agent's only.
4. `sourceTag` / `sourceRef`: (a) tag `patchbay.assist`, ref = payer wallet address —
   recommended; (b) ref = the payment's own identifier instead.
