# USDC Offers

6 Nov 2026. Patchbay chief engineer, on HQ's order of 15:52Z relaying Sean: "drop the
credits system entirely . remove it from points, remove it from patchbay. Where they were
used in patchbay will become a pure USDC on Base system, with an onramp / deposit , and a
live contract for the offers (designed for patchbay.help but extensible to more sites in
the future, serving as a marketplace for offer inventory and demand)".

This is a design note on a branch. It deploys no contract and touches no production data.
The contract it describes is `RegentOffers` on `pb/regent-offers-moderator-1106`, with
the fixes from the second and third reviews and Sean's letters 13 a, 14 b and 15 a. Every Credits balance and every open Credits bid stays
exactly as it is until the cutover release. Building the contract, the reader and the
pages is ordinary work on side branches. The contract deploy, its owner, operator and
moderator wallets, the new tables in the shared production database, and the cutover
release all wait for Sean's named go.

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
  holds `PatchbayEscrow` (Base `0xfa9c4de927b8fc62e87b9e48b1e29a205c25adfe`), for
  priority-report bounties, beside `RegentOffers`, which is not deployed.
  - The escrow keeps a 90/10 split and allows a refund to anyone after 30 days.
  - It has no pause, no upgrade and no sweep.
  - Nothing in it serves Offers.

## Shape

The Offers market moves to one new contract, **RegentOffers**, on Base, in USDC. It is a
marketplace with two sides:

- **Inventory**: the slots on a site's forums.
- **Demand**: the bids that pay for them.

Patchbay.help is its first site, and other Regent sites can join it later.

Patchbay keeps what it is good at: screening wordings, the slot order, the two-second
windows and choosing winners, all of which are tested today. The contract keeps the money,
under rules a stolen key cannot bend.

### Contract

Foundry, in `contracts/` beside `PatchbayEscrow`.

- **Sites (venues).** The owner adds a site: its id (`keccak256("patchbay.help")`), its
  admin, its operator (the site's server key), its moderator, its payout wallet, its
  opening minimum in USDC base units and its placement length (72 hours on Patchbay).
  - The site's admin can replace its operator, and change its minimum and length for new
    bids.
  - Only the owner replaces a site's admin, sets its moderator and names its payout wallet.
    A site's admin can no longer point the site's money at a new wallet.
  - The moderator is never the site's admin or its operator. Every function that sets one of
    the three refuses a moderator equal to either of the other two. Regents Labs holds the
    moderator key in a hardware wallet or a Safe (Sean, 15 a).
- **Slots.** Every site with a forum gets three Offer slots on each forum (Sean, 5). There
  is no listing step: any slot id of a site takes bids, and which forum and slot number
  it means is Patchbay's, kept in the slot id.
- **Demand: a bid is signed, not sent** (Sean, 14 b). One bid path only: the bidder signs
  one USDC EIP-3009 `ReceiveWithAuthorization` with `to` set to RegentOffers, and anyone
  submits `bid(terms, bidder, validAfter, validBefore, signature)`: the site, or the bidder.
  - `terms` holds the site, slot, lane, wording hash, amount, placement length, `placeBy`
    and the bidder's salt.
  - The authorization's nonce is `nonceOf(terms)`, `keccak256(abi.encode(market, terms))`, and the
    contract recomputes it from the call. A signature funds only that exact bid: any other
    site, slot, lane, wording, amount, length, deadline or salt gives a different nonce,
    and USDC refuses it.
  - Only the contract can use the signature, because USDC accepts a
    `ReceiveWithAuthorization` only from its `to`. A copy seen in the mempool cannot be
    turned into a plain transfer.
  - USDC checks the signature, its time window and its nonce: an account with no code by
    its key, and a contract wallet or an EIP-7702 account through ERC-1271 (the `bytes`
    form). The contract checks that exactly the amount arrived.
  - A bid's id is `bidIdOf(bidder, terms)`, `keccak256(bidder, terms)`. Whoever submits a
    signature first makes the bidder's own bid; a second submission is refused, and someone
    copying another bidder's terms needs their own signature for a bid of their own.
  - Until it is used, the bidder can cancel a signature with USDC's `cancelAuthorization`.
  - `bid` is refused below the site's minimum, for an unknown site, for a zero slot, when
    the length is not the site's length, after `placeBy`, when `placeBy` is more than
    `MAX_WAIT` (72 hours) away, or while new bids are paused.
  - Each bid keeps the payout wallet its site named when it was made. A later payout
    change, even one made with a stolen owner key, is paid only for bids made after it.
    Bids already made pay the wallet stored with them, even when the site has had to leave
    that wallet.
  - It works the same for a card buyer, an outside wallet, a contract wallet and an agent
    with its own wallet.
- **Operator steps.** Each step is bounded by the contract:
  - `place(bidId)` turns a held bid into the slot's placement, starting at the block's own
    time. There is no start time to pass, so nothing can be backdated or set ahead. It is
    refused after the bid's `placeBy`.
  - A slot has at most one live placement. Placing onto a slot that is showing an Offer
    ends that placement in the same call, as replaced, and its unused time goes back, so a
    buyout is atomic (decision 13).
  - `returnBid(bidId)` gives a held bid back in full.
- **Moderator step.** `remove(bidId)` ends a showing placement for policy, and the whole
  bid is paid, with nothing back (Sean, 4 b). Only the site's moderator may remove, and it
  is never the operator or the admin, so neither the key that places nor the key that names
  who places can also charge a bid in full.
- **Steps anyone may take.** Each of these pays only the people the bid names, so nobody
  depends on Patchbay running:
  - `withdraw(bidId)` gives back a bid never placed, once its `placeBy` has passed;
  - `finish(bidId)` ends a placement whose time is up, all of it used;
  - `payOut(account)` sends an account everything it is owed;
  - `pushRevenue()` sends the protocol share to REGENT staking.
- **Money rules the contract enforces, whatever the operator does.**
  - Bid money leaves only two ways: back to its bidder, or as payment for its placement.
  - A replaced placement pays `amount × shown ÷ length`, rounded down, and the bidder gets
    the rest back, so returned plus used is always the bid. A finished or removed
    placement pays the whole bid.
  - Of what is paid, 10% goes to REGENT staking through `depositUSDC` and 90% to the
    bid's payout wallet (Sean, 3 a). The share and the staking contract are fixed at
    deploy.
  - The USDC token and the staking contract are refused as payout wallets, and so is the
    contract itself.
  - Ending a bid never sends USDC. Everything owed is recorded first, and `payOut` sends it
    afterwards. Circle can block an address from receiving USDC, and with a direct send a
    blocked bidder would jam their slot, because nothing could end the placement and
    nothing could be placed after it. Patchbay's server calls `payOut` after each end, so
    people are paid at once.
  - USDC sent to the contract other than through a bid can be sent on only by the owner,
    with `recoverSurplus`, which pays the balance above every liability and nothing else.
    There is no other owner withdrawal and no ETH.
- **Pause, no upgrade.** The owner can pause new bids. Placing, returns, withdrawals,
  removals, finishing and payouts never pause. A new version is a new contract that sites
  move to, with this one paused (Sean, 8 a).
- **Stolen operator key.** A thief can do three things, and cannot take any money:
  - return bids;
  - place one bid per slot at a time, which charges only for time actually shown,
    starting now;
  - replace a placement, which pays back its unused time.

  Holding a slot for a full 72 hours charges one bidder for 72 hours of showing, paid to
  the bid's payout wallet, never to the thief.
- **Stolen moderator key.** A thief can remove showing placements, which charges those
  bids in full, paid to their payout wallets, never to the thief (decision 15).
- **Stolen admin key.** A thief can name its own operator and change the terms, and so
  place bids, but it cannot name the payout wallet or the moderator, so every bid it places
  still pays the site, before or after the theft.
- **Stolen owner key.** A thief can name its own payout wallet, admin, operator and
  moderator, and then take 90% of every bid made after that, in the bid's own block. There
  is no timelock, so **the owner must be a multi-owner Safe**. Bids made before the theft
  still pay the wallets stored with them.
- **Events.** One event per change:
  - `VenueAdded`, `VenueAdminChanged`, `OperatorChanged`, `ModeratorChanged`,
    `PayoutChanged`, `VenueTermsChanged`;
  - `BidPlaced`, `BidReturned`, `BidWithdrawn`;
  - `Placed`, `Ended` (with the reason, used, returned and each share);
  - `PaidOut`, `RevenuePushed`, `PausedSet`.
- **Checks.**
  - `make check-contracts`: `forge fmt --check`, `forge build` and the offline tests.
  - Unit, fuzz, role and stolen-key tests, every bid a signature submitted by someone else:
    a wrong signer, changed terms under a valid signature, another market, the time window,
    a used or cancelled nonce, a front-run, and a contract wallet through ERC-1271.
  - Invariants over two sites and random steps: the contract's USDC always equals what is
    held and placed, plus what is owed, plus the revenue owed, plus any USDC sent to it
    directly; every account is credited what an independent book says; a slot never has
    two live placements.
  - `slither` and `forge lint`, both clean.
  - `make check-contracts-fork`: tests on the real Base USDC and REGENT staking on a local
    fork, never broadcast, for three bidders, each through to payment: a plain account; an
    EIP-7702 account whose delegate answers `isValidSignature`, accepting a plain 65-byte
    signature by the account's own key over the exact EIP-712 digest (a delegate without
    it is refused); and a contract wallet.
  - Broken copies of the contract each turn the offline tests red. The break runner,
    `uv run --no-project contracts/test/breaks/breaks.py`, holds every break: the second
    review's eighteen (role checks, zero values and addresses in every setter, the events
    carrying the bid's own values, the approval left with staking), the owner-only payout
    wallet, the moderator kept apart in each setter, the signature checks (the submitter
    taken as the bidder, money taken from the submitter, the id leaving out the bidder, the
    nonce leaving out a term or being the salt alone, the time window dropped, submitting
    limited to the operator), the pause, and the earlier ones (the received-amount check,
    the re-entry guard, the 72-hour cap).

### Funding

The onramp and deposit path.

- **A person** pays from their own Privy wallet. Its **USDC Balance** is read live and is
  shown in the account menu where Credits sit today. Add USDC opens two ways (Sean, 6 a
  then b):
  - **Card**: Privy's card window, already live, puts USDC on Base into that wallet.
  - **Send**: the wallet's full address, with a copy icon and a QR code, for USDC on Base
    from an exchange or another wallet.
- **An agent with its own wallet** is funded by its person, or by anyone, sending USDC on
  Base to its address. Card purchases need a person in the browser, so an agent cannot buy
  by card for itself.
  - The agent reads its USDC Balance through `account_balances`, which gains a `usdc`
    field.
  - Its own key signs each bid. The site builds what to sign and never holds the key.
- **Gas.** Signing needs no ETH. A signed bid is submitted by the site or by the bidder,
  and the Base paymaster (Sean, 7 a) covers it, so a card buyer can bid straight away with
  no ETH. An agent that owns a Privy account is sponsored the same way.
- **No balance is kept by Regents.** Money sits in the wallet until a bid commits it to the
  contract. Committed money is shown apart, as "In Offers", beside the USDC Balance.

### Chain reader

The `chain-events` pattern.

- **Reading job.** One AshOban reading job for RegentOffers on Base, unique by contract.
  It runs a pass and snoozes five minutes, and it snoozes 60 seconds if the node does not
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
- **Bids and placements come from those rows.** The watcher records each `BidPlaced`, and
  `offer_bids` and `offer_placements` are written from the event rows in the same
  transaction as the cursor. The chain is the record of money, and the Credits columns go.
- **Pages hear after commit.** Rows publish through `Ash.Notifier.PubSub` after commit. An
  open page reads again at most once a second, and figures every visitor sees alike (a
  slot's showing Offer and its least bid) are read once and shared.
- **Reading early.** A confirmed step (`OnchainSteps.checked/3`) and the read-again icon
  bring the next pass forward to ten seconds away (`ChainRefresh.request/1`), at most once
  every ten seconds. The step's own receipt is read every quarter second for the button's
  words.
- **Catching up.** A notice shows once the head was read over 420 seconds ago, or once the
  record is over 3,000 blocks behind it.
- **Model.** The model is Keyfleet's reader. Patchbay's escrow reads (`Patchbay.Escrow.Watch`,
  per-report polling) stay as they are.
- **Jobs after the chain.** Patchbay's own steps (submitting a signed bid, `place`,
  `returnBid`, `withdraw` after `placeBy`, `finish`, `payOut` after each end) are Oban jobs
  sent with the operator key, and `remove` is sent with the moderator key.
  - Each job is unique by bid.
  - Each step is safe to repeat, because the contract refuses a second one.
  - A job reads the chain, sends, then writes, and never sends inside a database
    transaction.

### Buttons

Bid follows `onchain-buttons` and `payments`, as a signature:

- The server builds the typed data. The browser never encodes a transaction.
- Every press reaches the wallet as a signature request, including a repeat press while
  one is pending. A repeat press signs with a new salt, so a duplicate bid is an accepted
  outcome, and the server returns the extra in full.
- A signature stays good for ten minutes (`validBefore`). The site submits it at once;
  until then the bidder can submit it themselves.
- Bid is disabled only by the chain's own state at the latest block, with these words
  beside it, and comes back once that state changes:
  - "Below the minimum";
  - "Not enough USDC";
  - "Bids paused".
- The server checks each result at the latest block and shows pending, done or reverted;
  the chain watcher records `BidPlaced` for good.
- The 110% replacement rule and the wording screen are Patchbay's server rules, not the
  chain's. A bid under them lands, is returned in full, and the page says why.

### Agent surfaces

Every action reaches one server door, through five surfaces:

- the website in a headless browser;
- WebMCP;
- hosted `/mcp`;
- the signed HTTP route;
- the regents CLI.

Each surface carries the same words and refusals. Steps the operator or moderator sends
(place, return, remove, finish, pay out) are the site's server, not an account owner's
action.

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

## Credits removal

One release removes everything below, with no Credits branch kept:

- the Buy Credits panel, `credits.ts`, `CreditsLimit` and the Credits row and card;
- `Patchbay.Credits`, `Offers.Holds` and `CreditAmount`;
- `account_credits_history` and its CLI command;
- the Credits fields in `account_balances` and `get_offer_bid_options`;
- the `regent_credits` config and dependency;
- the Credits walks and tests;
- the feature-map and parity rows, and every guide's Credits words.

Credits help goes once the three buyers are paid back (decision 12). Points drops its
"Credits purchases" rule through the template chief's rollout file, and Patchbay's Points
branch takes that change once it lands.

## Order

1. **Contract.** RegentOffers and its checks on a side branch, with an adversarial review
   by a separate agent given the code and the question. Two reviews are done, and the
   second review's fixes are in.
2. **Reader.** The reading job, the tables and their notices, run against a local Base
   fork (anvil) with the contract deployed there.
3. **Pages and agent surfaces.** Bid, Withdraw, Add USDC and USDC Balance on the
   five surfaces, walked at 320, 390 and 1280.
4. **Sean's go.** On his named go: deploy the contract, set the owner Safe (a multi-owner
   Safe Sean names), the operator and moderator keys, Patchbay as a site, and add the tables
   to production.
5. **Cutover release.** One release closes Credits bidding, removes the Credits code above
   and opens Offers on USDC.

## Bid path

Signed bids are the one bid path (Sean, 14 b), replacing approve then bid, with no second
path kept.

- **Checked again.** Each check approve then bid had dropped was looked at again for the
  signed path:
  - a zero bidder can never pass USDC's signature check, so it needs no check of its own;
  - the contract as bidder has no `isValidSignature`, so USDC refuses it;
  - the received-amount check stays;
  - a front-run makes the same bid for the same bidder, and the second submission is
    refused;
  - a used or cancelled authorization is refused by USDC.
- **The submitter controls timing.** Whoever holds a signature chooses when to submit it,
  until `validBefore`, ten minutes. The terms cannot change, because the nonce binds them.
  The payout wallet is the one the site names when the bid is made, and only the owner
  names it.
- **Cancelling a signature.** A bidder may cancel a signature before it lands, and the
  submission then fails. That is an accepted outcome.
- **New smart wallets.** A smart-contract wallet that has not been deployed yet cannot sign
  for USDC: USDC checks ERC-1271 and not ERC-6492. This is the same limit x402 has today.
- **Not proven: Privy wallets.** Privy's own EIP-7702 delegate, and the form of signature
  its `isValidSignature` accepts, are not documented. The fork tests prove a 7702 account
  whose delegate accepts a plain signature by the account's own key. A Privy wallet stays
  unproven until a real one signs a bid on a lab chain.
- **Spam.** Each bid commits at least the site's minimum of real USDC, so a spam bid locks
  only the spammer's own money, and no bid waits longer than `placeBy`, at most 72 hours.
  Patchbay keeps its request limits on the prepare and submit doors, which bounds the
  sponsored gas.

## Accepted limits

These came out of the two reviews of the contract and are accepted as they are, each stated
in the contract's own notes.

- **N1c Owner key.** One stolen owner key takes 90% of every later bid at once. There is no
  timelock; the owner must be a multi-owner Safe, and which Safe is Sean's to name with the
  deploy decision.
- **N1d Clean-up by replacement.** A placement that should not be showing, such as one
  placed while a key was stolen, is cleaned up by replacing it with another bid, which
  returns its unused time. Never by removal, which pays the whole bid to the wallet stored
  with it.
- **N2 Stored wallet.** Bids already made pay the payout wallet stored with them, even after
  the site names a new one because it had to leave the old one.
- **F4 Blocked payout wallet.** Money owed to an address Circle has blocked waits until
  USDC will pay it. Nothing can send it elsewhere: a way to pay to another address would
  only help a blocked wallet route around Circle's block.
- **F5 Staking share.** The protocol share waits in the contract for as long as the staking
  contract refuses deposits, and anyone pushes it once staking takes deposits again. The
  staking contract is fixed at deploy, so the share has no other way out.
- **F6 Stray USDC.** USDC sent to the contract other than through a bid is in no record. Only
  the owner can send it on, with `recoverSurplus`, which pays out only the balance above
  everything held and owed (review 3, F18).
- **Review 3.** Its six lows and twelve notes are written into the contract's header and
  `contracts/README.md`. In code, round 5: a signature is good for at most an hour after it is
  submitted (F12), the nonce names the market (F16), and the owner can recover surplus USDC
  (F18). A pause already stopped new bids only (F1).

## Decisions

### Sean's letters

Given on 6 Nov 2026, recorded as given:

- 1 Custody: a.
- 2 Funding: a.
- 3 Fees: a. 10% to REGENT staking, 90% to the site's payout wallet.
- 4 Removal: b. No refunds: a removal for policy pays the whole bid.
- 5 Listing: every site with a forum gets 3 Offer slots.
- 6 Onramp: a, then b.
- 7 Gas: a. Paymaster on Base.
- 8 Upgrades: a. A new contract, moved to through a pause, instead of an upgrade.
- 9 Keys: a.
- 10 Auction rules: a.
- 11 Cutover: b.
- 12 Leftover balances: a.
- 13 Unused time on a buyout: a. A replaced placement's unused time goes back to its
  bidder, as the contract has it.
- 14 Bid path: b. Signed bids submitted by anyone, replacing approve then bid.
- 15 F1 Full charge on removal: a. A removal charges the whole bid, and Regents Labs holds
  the moderator key in a hardware wallet or a Safe.

### HQ rulings

- The payout wallet is kept per bid (F2, F3).
- The moderator is set by the owner and is never the operator or the admin.
- The USDC token and the staking contract are refused as payout wallets (F4 b).
- `MAX_WAIT` is 72 hours, one placement length (F7).
- F4, F5 and F6 are accepted, as above.
- After the second review (18:22Z): only the owner names a site's payout wallet (N1a, N1b);
  the owner must be a multi-owner Safe, with no timelock (N1c); clean-up is by replacement
  (N1d); bids already made pay their stored wallet (N2); the moderator is never the admin or
  the operator, checked in every function that sets one of them (N3). A removal still
  charges the whole bid (F1).

## Later

- The contract deploy, the wallets, the tables in the shared production database and the
  cutover release. Each needs its own named go.
