# Agent Offers in USDC on Base: design note

6 Nov 2026. Patchbay chief engineer, on HQ's order of 15:52Z relaying Sean: "drop the
credits system entirely . remove it from points, remove it from patchbay. Where they were
used in patchbay will become a pure USDC on Base system, with an onramp / deposit , and a
live contract for the offers (designed for patchbay.help but extensible to more sites in
the future, serving as a marketplace for offer inventory and demand)".

This is a design note on a branch. It changes no code, deploys no contract and touches no
production data. Every Credits balance and every open Credits bid stays exactly as it is
until the cutover release. Building the contract, the reader and the
pages is ordinary work on side branches. The contract deploy, its owner and operator
wallets, the new tables in the shared production database, and the cutover release all
wait for Sean's named go.

## Today

- **Credits spend.** Bidding for an Agent Offer is the only thing Credits pay for on
  Patchbay. A bid's full amount is held in the shared `regent_credits` ledger under the
  bid's id (`Patchbay.Offers.Holds`). It moves to the placement when the bid wins, and is
  settled into returned, used and forfeited parts when the placement ends. The used part
  goes to the Regent revenue account inside the ledger.
- **Market rules.** Each site market has three slots, and a Global market has three more.
  A bid needs at least 1.00 (the opening minimum; a site market may set its own). A bid
  that replaces what is showing needs at least 110% of it. Bids gather in a two-second
  window. A placement runs 72 hours. A buyout gives the replaced placement its unused
  time back, and a removal for policy forfeits the unused time. Agent spending is off.
- **Already on USDC through x402.** Three things are paid from the payer's own wallet on
  Base mainnet today, and none of them takes Credits:
  - paid priority reports, which pay into `PatchbayEscrow`;
  - paid assists, a 0.10 USDC fee that is forwarded to REGENT staking;
  - agent tips, which have no page yet.
- **Card purchases.** Privy's card window (`useFiatOnramp`, Stripe or MoonPay) already
  buys USDC on Base into the signed-in wallet.
- **Contracts.** `/Users/sean/Documents/regent/worktrees/patchbay/draft-check-1027/contracts`
  holds one contract, `PatchbayEscrow` (Base `0xfa9c4de927b8fc62e87b9e48b1e29a205c25adfe`),
  for priority-report bounties.
  - It keeps a 90/10 split and allows a refund to anyone after 30 days.
  - It has no pause, no upgrade and no sweep.
  - Nothing in it serves Offers.

## Shape

The Offers market moves to one new contract, **RegentOffers**, on Base, in USDC. It is a
marketplace with two sides:

- **Inventory**: the slots a site lists.
- **Demand**: the bids that pay for them.

Patchbay.help is its first site, and other Regent sites join it later.

The contract is written and checked on the side branch `pb/regent-offers-contract-1106`
(`f9dd89c0`): `contracts/src/RegentOffers.sol`, its tests in `contracts/test/` and a fork walk
in `contracts/script/OffersSanity.s.sol`. Nothing is deployed.

Patchbay keeps what it is good at: screening wordings, the slot order, the two-second
windows and choosing winners, all of which are tested today. The contract keeps the money,
under rules a stolen key cannot bend.

### Contract (Foundry, `contracts/` beside `PatchbayEscrow`)

- **Sites (venues).** The owner adds a site: its id (`keccak256("patchbay.help")`), its
  admin, its operator (the site's server key), its payout wallet, its opening minimum in
  USDC base units and its placement length (72 hours on Patchbay). A site's admin can
  replace its operator and payout wallet and change the minimum and length for bids from
  then on; the owner can replace a site's admin.
- **Inventory comes with the forum** (Sean, 6 Nov: "All sites that have a forum
  automatically get 3 offer slots, so all sites"). There is no listing step. Every forum a
  site runs has three slots, and Patchbay has three Global slots as well. The slot id is
  Patchbay's (the forum's market and slot number), and the bidder signs it, so a bid can
  only ever be placed in the slot it was made for.
- **Demand: a bid is signed, not sent.** The bidder signs one USDC EIP-3009
  `ReceiveWithAuthorization` with `to` set to RegentOffers. Anyone then submits
  `bid(terms, bidder, validAfter, validBefore, signature)`; Patchbay's operator does, and
  pays the gas, so the bidder needs no ETH.
  - `terms` holds the site, slot, lane, wording hash, amount, placement length, `placeBy`
    and the bidder's salt.
  - The authorization's nonce is `keccak256(abi.encode(terms))`, and the contract
    recomputes it from the call. A signature can fund only that exact bid: any other site,
    slot, lane, wording, amount, length or deadline gives a different nonce, and USDC
    refuses it.
  - Only the contract can use the signature, because USDC accepts a
    `ReceiveWithAuthorization` only from its `to`. A copy seen in the mempool cannot be
    turned into a plain transfer.
  - A bid's id is `keccak256(bidder, nonce)`, so nobody can take another bidder's id first
    by copying their terms.
  - `bid` is refused below the site's opening minimum, for an unknown site, when the length
    is not the site's length, after `placeBy`, or while new bids are paused.
  - Contract wallets sign through the `bytes` signature form that USDC v2.2 checks with
    ERC-1271.
  - This is the same signature tips, assists and priority reports already ask for through
    x402. It works the same for a card buyer, an outside wallet and an agent.
- **Operator steps.** Each step is bounded by the contract:
  - `place(bidId)` turns a held bid into the slot's placement, starting at the block's own
    time. There is no start time to pass, so nothing can be backdated or set ahead. It is
    refused after the bid's `placeBy`.
  - A slot has at most one live placement. Placing onto a slot that is showing an Offer
    ends that placement in the same call, as replaced, and its unused time goes back, so a
    buyout is atomic.
  - `returnBid(bidId)` gives a held bid back in full.
  - `remove(bidId)` ends a placement for policy, and the whole bid is paid (Sean, 4 b:
    "we are removing refunds entirely").
- **Steps anyone may take.** Each of these pays only the people the bid names, so no
  bidder needs ETH and nobody depends on Patchbay running:
  - `withdraw(bidId)` gives back a bid never placed, once its `placeBy` has passed;
  - `finish(bidId)` ends a placement whose time is up, all of it used;
  - `payOut(account)` sends an account everything it is owed;
  - `pushRevenue()` sends the protocol share to REGENT staking.
- **Money rules the contract enforces, whatever the operator does.**
  - Bid money leaves only two ways: back to its bidder, or as payment for its placement.
  - A bid never placed comes back in full.
  - A placement that runs its length, or is removed for policy, pays the whole bid.
  - A placement replaced by a newer one pays `amount × shown ÷ length`, rounded down, and
    the bidder gets the remainder, so returned plus paid is always the bid.
  - What is paid divides 10% to REGENT staking through `depositUSDC` and 90% to the site's
    payout wallet (Sean, 3 a). The share and the staking contract are fixed at deploy.
  - Ending a bid never sends USDC. Everything owed is recorded first, and `payOut` sends it
    afterwards. Circle can block an address from receiving USDC, and with a direct send a
    blocked bidder would jam their slot, because nothing could end the placement and
    nothing could be placed after it. Patchbay's server calls `payOut` after each end, so
    people are paid at once.
  - There is no sweep, no owner withdrawal and no ETH.
- **Stolen operator key.** A thief cannot take any money; every payment goes to the
  bidder or to the site's payout wallet and REGENT staking, never to the thief. A thief can:
  - return bids;
  - place a bid in the slot it was made for, starting now;
  - replace a placement, which pays back its unused time;
  - remove a placement, which pays the whole bid (4 b).

  So a thief can charge every held bid in full, one after another: place it, then remove it.
  The money lands in the site's own payout wallet and REGENT staking, so it can be handed
  back by the team, but the contract cannot undo it. Before 4 b the cap was one placement
  per slot for time actually shown.
- **Events.** One event per change:
  - `VenueAdded`, `VenueAdminChanged`, `OperatorChanged`, `PayoutChanged`,
    `VenueTermsChanged`;
  - `BidPlaced`, `BidReturned`, `BidWithdrawn`;
  - `Placed`, `Ended` (with the reason, used, returned and each share);
  - `PaidOut`, `RevenuePushed`, `PausedSet`.
- **Checks, run on `f9dd89c0`.**
  - `forge fmt`, `forge lint` (no warnings left; each deliberate one is explained beside
    its line) and `slither` (0 findings).
  - `forge test`: 47 tests, 0 failed. Of these, 31 are Offers unit and fuzz tests:
    - a signature funds only its exact terms, once;
    - paid plus returned is always the bid, and the shares are always what was paid;
    - pause stops new bids only;
    - a placement starts at the block time, and a slot has one live placement;
    - a removal pays the whole bid;
    - a blocked bidder never jams a slot;
    - revenue waits out a paused staking contract and refuses one that takes too little;
    - smart-wallet bids through ERC-1271.
  - Three invariants over 256 runs of 500 random calls each (bids, places, returns,
    removals, withdrawals, finishes, payouts, pushes, stray USDC and time):
    - the contract's USDC always equals what is held and placed, plus what is owed, plus
      the revenue owed, plus USDC sent to it directly;
    - what is held equals the sum of held and placed bids;
    - a slot never shows two placements.
  - `OffersSanity.s.sol` on a fork of Base mainnet, never broadcast: two signed bids
    through real USDC, a replacement after an hour, a full run, a bid returned after its
    deadline, payouts, and the protocol share into the real REGENT staking contract.

### Funding a wallet (the onramp and deposit path)

- **A person** pays from their own Privy wallet. Its **USDC Balance** is read live and is
  shown in the account menu where Credits sit today. Add USDC opens two ways now (Sean, 6
  a then b):
  - **Card**: Privy's card window, already live, puts USDC on Base into that wallet.
  - **Send**: the wallet's full address, with a copy icon and a QR code, for USDC on Base
    from an exchange or another wallet.
  - **Later**: Coinbase Onramp as a second card provider, in its own change.
- **An agent with its own wallet** is funded by its person, or by anyone, sending USDC on
  Base to its address. Card purchases need a person in the browser, so an agent cannot buy
  by card for itself.
  - The agent reads its USDC Balance through `account_balances`, which gains a `usdc`
    field.
  - Its own key signs each bid. The site prepares what to sign and never holds the key.
- **No ETH.** Signing needs no ETH, and the steps that come after are sent by Patchbay or
  by anyone. A card buyer can bid straight away.
- **No balance is kept by Regents.** Money sits in the wallet until a bid commits it to the
  contract. Committed money is shown apart, as "In Offers", beside the USDC Balance.

### Reading the chain (chain-events)

- **Reading job.** One AshOban reading job for RegentOffers on Base, unique by contract.
  It runs a pass and snoozes five minutes, and it snoozes 60 seconds when the node does not
  answer. A watch on the Oban cron makes sure the job exists.
- **Cursor.** One cursor row holds the first unread block, the head last seen and
  `rescan_from`.
- **Each pass:**
  - reads at `latest`;
  - re-reads the newest 300 blocks;
  - reads forward in stretches of up to 10,000 blocks, halving a stretch the node
    refuses;
  - reports `[:patchbay, :indexer, :lag]`, which becomes Sentinel's
    `health_indexer_lag_blocks`.
- **Block time, measured.** Base mainnet, read at `latest` at 15:59:14Z on 6 Nov 2026
  (head 53,951,896):
  - the newest 300 blocks spanned 60 seconds;
  - the newest 3,000 blocks spanned 600 seconds.

  That is 200 ms a block. The re-read is therefore 300 blocks (one minute), and the
  catching-up allowance is 3,000 blocks (ten minutes).
- **One event table.** `offer_chain_events` has identity `[:chain_id, :transaction_hash,
  :log_index]` and is written once, never overwritten. Each row carries the block number
  and hash, with amounts as raw `:decimal`. A re-read that disagrees, or a block whose hash
  changed, stops the watcher for a person to fix.
- **Bids and placements come from those rows.** `offer_bids` and `offer_placements` are
  written from the event rows in the same transaction as the cursor. The chain is the
  record of money, and the Credits columns go.
- **Pages hear after commit.** Rows publish through `Ash.Notifier.PubSub` after commit. An
  open page reads again at most once a second, and figures every visitor sees alike (a
  slot's showing Offer and its least bid) are read once and shared.
- **Reading early.** A confirmed submission (`OnchainSteps.checked/3`) and the read-again
  icon bring the next pass forward to ten seconds away (`ChainRefresh.request/1`), at most
  once every ten seconds. The submission's own receipt is read every quarter second for
  the button's words.
- **Catching up.** A notice shows when the head was read over 420 seconds ago, or when the
  record is over 3,000 blocks behind it.
- **Model.** The model is Keyfleet's reader. Patchbay's escrow reads (`Patchbay.Escrow.Watch`,
  per-report polling) stay as they are.
- **Jobs after the chain.** Patchbay's own steps (submitting a signed bid, `place`,
  `returnBid`, `remove`, `withdraw` after `placeBy`, `finish`, `payOut` after each end) are
  Oban jobs signed with the operator key.
  - Each job is unique by bid.
  - Each step is safe to repeat, because the contract refuses a second one.
  - A job reads the chain, sends, then writes, and never sends inside a database
    transaction.

### Buttons

Bid follows `onchain-buttons` and `payments`, as a signature:

- The server builds the typed data. Every press reaches the wallet as a signature request,
  including a repeat press while one is pending.
- A repeat press signs with a new salt, so a duplicate bid is an accepted outcome, and the
  server returns the extra in full.
- Bid is disabled only when the chain makes it certain to fail, read at the latest block:
  - "Below the minimum";
  - "Not enough USDC";
  - "Bids paused".
- The 110% replacement rule and the wording screen are Patchbay's server rules, not the
  chain's. A bid under them lands, is returned in full, and the page says why.
- An authorization stays good for ten minutes (`validBefore`). Patchbay submits it at
  once; until then the bidder can submit it themselves.

### Agent surfaces

Every action reaches one server door, through five surfaces:

- the website in a headless browser;
- WebMCP;
- hosted `/mcp`;
- the signed HTTP route;
- the regents CLI.

Each surface carries the same words and refusals. Steps the operator signs (place, return,
remove, finish, pay out) are the site's server, not an account owner's action.

| Action | Website | WebMCP | /mcp | HTTP | CLI |
| --- | --- | --- | --- | --- | --- |
| Read USDC Balance and In Offers | account menu, `/account` | `account_balances` | `account_balances` | `GET /tools/account/balances` | `account balances` |
| Add USDC | Add USDC: card window, or address and QR code | `get_funding_address` | `get_funding_address` | `GET /tools/account/funding` | `account funding` |
| Read slots and bid options | `/offers`, `/offers/bid` | `list_offer_slots`, `get_offer_bid_options` | same | same routes | `offers slots`, `offers bid-options` |
| Prepare a bid (what to sign) | `/offers/bid` Bid | `prepare_offer_bid` | `prepare_offer_bid` | `POST /forum/offer-bids/prepare` | `offers bid` (signs with the agent's key) |
| Submit a signed bid | the hook sends the signature | `submit_offer_bid` | `submit_offer_bid` | `POST /forum/offer-bids` | `offers bid` |
| Withdraw a bid never placed | `/offers/active` Withdraw | `withdraw_offer_bid` | `withdraw_offer_bid` | `POST /forum/offer-bids/withdraw` | `offers withdraw` |
| Read active Offers and history | `/offers/active`, `/offers/history` | `list_my_active_offers`, `list_my_offer_history` | same | same routes | `offers active`, `offers history` |

- **New names.** `get_funding_address`, `prepare_offer_bid`, `submit_offer_bid`,
  `withdraw_offer_bid`, their routes, and `offers withdraw` and `account funding` are
  proposed names. `bid_on_offer_slot` gives way to the prepare and submit pair.
- **Withdraw.** Withdraw asks Patchbay to send `withdraw` after `placeBy`. Patchbay also
  sends it for every unplaced bid on its own, and anyone may send it.
- **Card.** "Add USDC" by card is a person's step in Privy's window. The agent row is the
  address path, so this is not a person-only action.
- **Agent spending switch.** It goes away, because an agent spends its own wallet's USDC
  with its own key and never its person's.
- **Paid tools.** A bid is a signed USDC authorization, as x402 payments are, but it is
  submitted to the contract, not to a facilitator. Paid tools keep x402.

## Credits leave Patchbay (hard cutover)

One release removes everything below, with no Credits branch kept:

- the Buy Credits panel, `credits.ts`, `CreditsLimit` and the Credits row and card;
- `Patchbay.Credits`, `Offers.Holds` and `CreditAmount`;
- `account_credits_history` and its CLI command;
- the Credits fields in `account_balances` and `get_offer_bid_options`;
- the `regent_credits` config and dependency;
- the Credits walks and tests;
- the feature-map and parity rows, and every guide's Credits words.

Credits help goes once the three buyers are paid back (decision 12). Points drops its "Credits
purchases" rule through the template chief's rollout file, and Patchbay's Points branch
takes that change when it lands.

## Order of work

1. **Contract.** RegentOffers and its checks on a side branch, with an adversarial review
   by a separate agent given the code and the question.
2. **Reader.** The reading job, the tables and their notices, run against a local Base
   fork (anvil) with the contract deployed there.
3. **Pages and agent surfaces.** Bid, Withdraw, Add USDC and USDC Balance on the five
   surfaces, walked at 320, 390 and 1280.
4. **Sean's go.** On his named go: deploy the contract, set the owner Safe, the operator
   key and Patchbay as a site, and add the tables to production.
5. **Cutover release.** One release closes Credits bidding, removes the Credits code above
   and opens Offers on USDC.

## Signed bids: what was checked

Read at `latest` on Base mainnet, 6 Nov 2026:

- USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` uses the implementation at
  `0x2ce6311ddae708829bc0784c967b7d77d19fd779`, with EIP-712 domain version "2".
- That implementation carries both forms of `receiveWithAuthorization`: the `v, r, s` form
  and the `bytes` form that USDC v2.2 checks with ERC-1271 for contract wallets. It also
  carries `authorizationState` and `cancelAuthorization`.
- Patchbay's pages already sign USDC authorizations through Privy with
  `eth_signTypedData_v4` (`assets/js/wallet_actions/send_step.ts`) for x402.
  `ReceiveWithAuthorization` has the same fields under another type name.

The design holds. These limits came out of the check:

- **A blocked bidder could jam a slot.** Paying a bidder back with a direct send fails when
  Circle has blocked their address. Fixed above: everything owed is recorded first and
  paid by `payOut`.
- **The submitter controls timing.** Whoever holds the signature chooses when to submit it,
  until `validBefore`. It is kept to ten minutes, and `bid` is open to any caller so the
  bidder can send it themselves. The terms cannot change, because the nonce binds them.
- **New smart wallets.** A smart-contract wallet that has not been deployed yet cannot sign
  for USDC: USDC checks ERC-1271 and not ERC-6492. This is the same limit x402 has today.
  Privy's embedded wallets are ordinary accounts and are not affected.
- **Upgraded accounts.** An ordinary account that has been upgraded to a smart account
  (EIP-7702) has code, and USDC then asks that code to approve the signature instead of
  checking the key. Such a wallet can bid only if its account code approves signatures.
  The fork walk met this: the test tool's public sample address has been upgraded on Base,
  and real USDC refused its signature. x402 payments have the same limit today.
- **Gas spam.** Signed bids cost Patchbay's operator gas to submit and to pay back.
  - Each bid commits at least the slot's minimum of real USDC.
  - Patchbay keeps its request limits on the prepare and submit doors.
- **Cancelling a signature.** A bidder may cancel a signature before it lands
  (`cancelAuthorization`), and the submission then fails. That is an accepted outcome.

## Decisions

### Sean's answers (6 Nov, 16:04Z)

"1. a 2. a 3. a 4. b - we are removing refunds entirely 5. All sites that have a forum
automatically get 3 offer slots, so all sites. 6. a and then b 7. a - paymaster on Base 8.
a - I think we would install a new auction contract instead of upgrading it, through a pause
function 9. a 10. a 11. b 12. a"

- 1 a Custody: in the contract from bid to settlement.
- 2 a Funding: one signature per bid, with no balance kept by Regents.
- 3 a Fees: 10% to REGENT staking, 90% to the site's payout wallet, fixed at deploy.
- 4 b Removal for policy: the whole bid is paid. Open: how far "removing refunds
  entirely" reaches (below).
- 5 Slots: every forum on every site gets three slots, with no listing step; the owner adds
  each site.
- 6 a then b: Privy's card window and send to address now, Coinbase Onramp later.
- 7 a Paymaster on Base. Open: with one signature per bid nobody needs ETH (below).
- 8 a No upgrade: pause stops new bids only, and a new version is a new contract.
- 9 a The owner is Sean's Safe; the operator is a new key used only for Offers.
- 10 a Auction rules on Patchbay's server, with the operator bounded as above.
- 11 b and 12 a: below.

### Open with Sean

- **Refunds.** The contract today: a bid never placed comes back in full; a placement
  replaced by a higher bid returns its unused time; a removal for policy pays the whole bid.
  The question is whether a replaced placement should also keep nothing back.
- **Paymaster.** Bidding is one signature and Patchbay sends every transaction, so no
  bidder ever needs ETH and a paymaster has nothing to pay for. The question is whether to
  keep it that way or add one anyway.

### Answered earlier, kept for the record

3. **Fees and their receivers** (answered: a). How the money for shown time divides.
   - a) 10% to REGENT staking and 90% to the site's payout wallet (for patchbay.help, the
     Regents Labs treasury Safe), fixed at deploy.
   - b) All of it to REGENT staking.
   - c) All of it to the Regents Labs treasury.
   - Recommendation: a. It matches the priority-report escrow's 90/10, and it gives a
     future site a reason to list. The contract takes the share and receivers at deploy,
     so any letter works.
4. **Unused time on a removal for policy** (answered: b).
   - a) It goes back to the bidder. Disputes are handled by the team off the chain and paid
     from the treasury, and the contract never reverses a payment.
   - b) It is forfeited to the site, as today.
   - Recommendation: a. Real USDC taken by an operator's removal invites disputes, and with
     a) a stolen operator key cannot cost a bidder anything but shown time.
8. **Upgrades and pause** (answered: a). Whether the contract can be upgraded or paused.
   - a) No upgrade. The owner Safe can pause new bids and new listings only; placing,
     returns, withdrawals, finishing and payouts never pause.
   - b) Fully fixed, with no pause, like `PatchbayEscrow`.
   - c) An upgradeable proxy.
   - Recommendation: a. It can stop new money coming in during an incident without ever
     trapping money already in, and a new version is a new contract that sites move to.
9. **Owner and operator keys** (answered: a).
   - a) The owner is Sean's Safe, and the operator is a new key used only for Offers.
   - b) The operator reuses the escrow's operator key.
   - Recommendation: a. One key per contract keeps a leak to one market.

### Settled by the live count (Sean's letter, one read at 16:00Z)

The live count found five Credits purchases, all credited on Base, by three accounts, 70
USDC in all (7 to 26 Oct). There have been no gifts, no refunds and no holds of any status
on any site: no Credit has ever been held or spent on a bid.

- **11 b Cutover.** A Credits bid made before the cutover runs its course on Credits. The
  count found none open or showing, so in practice nothing carries over; the cutover
  release closes Credits bidding.
- **12 a Leftover balances.** The three buyers are paid back their 70 USDC one for one,
  then Credits close and Credits help goes with them. HQ runs the payback.

## Not decided here

- The contract deploy, the wallets, the tables in the shared production database and the
  cutover release. Each needs its own named go.
