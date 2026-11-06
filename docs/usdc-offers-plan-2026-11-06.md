# USDC Offers

6 Nov 2026. Patchbay chief engineer, on HQ's order of 15:52Z relaying Sean: "drop the
credits system entirely . remove it from points, remove it from patchbay. Where they were
used in patchbay will become a pure USDC on Base system, with an onramp / deposit , and a
live contract for the offers (designed for patchbay.help but extensible to more sites in
the future, serving as a marketplace for offer inventory and demand)".

This is a design note on a branch. It deploys no contract and touches no production data.
The contract it describes is `RegentOffers` on `pb/regent-offers-moderator-1106`, with
the fixes from the second review (HQ, 18:22Z). Every Credits balance and every open Credits bid stays
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
    the three refuses a moderator equal to either of the other two.
- **Slots.** Every site with a forum gets three Offer slots on each forum (Sean, 5). There
  is no listing step: any slot id of a site takes bids, and which forum and slot number
  it means is Patchbay's, kept in the slot id.
- **Demand: the bidder's own account bids.** One bid path only (HQ engineering ruling,
  17:20Z): the bidder's account sends `approve` on USDC for the amount, then calls
  `bid(terms)`.
  - `terms` holds the site, slot, lane, wording hash, amount, placement length, `placeBy`
    and the bidder's salt.
  - The bidder is always the caller. The amount is taken from the caller's own account,
    and the contract checks that exactly that amount arrived. An approval someone gave is
    spent only by that same account's own bid.
  - A bid's id is `keccak256(bidder, terms)`. The same bidder sending the same terms twice
    is refused, and someone copying another bidder's terms makes a bid of their own.
  - `bid` is refused below the site's minimum, for an unknown site, for a zero slot, when
    the length is not the site's length, after `placeBy`, when `placeBy` is more than
    `MAX_WAIT` (72 hours) away, or while new bids are paused.
  - Each bid keeps the payout wallet its site named when it was made. A later payout
    change, even one made with a stolen owner key, is paid only for bids made after it.
    Bids already made pay the wallet stored with them, even when the site has had to leave
    that wallet.
  - It works the same for a card buyer, an outside wallet, a contract account and an
    agent with its own wallet.
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
  - There is no sweep, no owner withdrawal and no ETH.
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
  - Unit, fuzz, role and stolen-key tests, every bid made as approve then bid from the bidder.
  - Invariants over two sites and random steps: the contract's USDC always equals what is
    held and placed, plus what is owed, plus the revenue owed, plus any USDC sent to it
    directly; every account is credited what an independent book says; a slot never has
    two live placements.
  - `slither` and `forge lint`, both clean.
  - `make check-contracts-fork`: tests on the real Base USDC and REGENT staking on a local
    fork, never broadcast, for a plain account, an account upgraded with EIP-7702 (one
    batched call, and two plain calls) and a contract account, each through to payment.
  - Broken copies of the contract each turn the offline tests red. The break runner,
    `uv run --no-project contracts/test/breaks/breaks.py`, holds every break: the second
    review's eighteen (role checks, zero values and addresses in every setter, the events
    carrying the bid's own values, the approval left with staking), the owner-only payout
    wallet, the moderator kept apart in each setter, and the earlier ones (money taken from
    someone other than the caller, the received-amount check, the re-entry guard, the
    72-hour cap).

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
  - Its own key sends Approve and Bid. The site builds both steps and never holds the key.
- **Gas.** Approve and Bid from a Privy wallet are both paid for by the Base paymaster
  (Sean, 7 a), so a card buyer can bid straight away with no ETH. An agent that owns a Privy
  account is sponsored the same way. Outside wallet apps, and an agent's own key outside
  Privy, pay their own Base gas.
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
- **Jobs after the chain.** Patchbay's own steps (`place`, `returnBid`, `withdraw` after
  `placeBy`, `finish`, `payOut` after each end) are Oban jobs sent with the operator key,
  and `remove` is sent with the moderator key.
  - Each job is unique by bid.
  - Each step is safe to repeat, because the contract refuses a second one.
  - A job reads the chain, sends, then writes, and never sends inside a database
    transaction.

### Buttons

Approve and Bid follow `onchain-buttons` and `payments`:

- The server builds both steps: the USDC approval for the bid's amount, and the `bid` call
  with its terms. The browser never encodes a transaction.
- Approve is its own step. Bid appears as soon as the approval is sent, and nothing waits
  for it to land before the next press can reach the wallet. Approve and Bid are the same
  size, and Approve turns grey with a green border once its transaction succeeds, still
  pressable.
- Every press reaches the wallet, including a repeat press while one is pending. A repeat
  Bid uses a new salt, so a duplicate bid is an accepted outcome, and the server returns
  the extra in full.
- Bid is disabled only by the chain's own state at the latest block, with these words
  beside it, and comes back once that state changes:
  - "Approve first", only while the chain shows no allowance for the amount;
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
| Build Approve and Bid | `/offers/bid` Approve, Bid | `prepare_offer_bid` | `prepare_offer_bid` | `POST /forum/offer-bids/prepare` | `offers bid` (sends both from the agent's wallet) |
| Check a sent step | the hook reports the hash | `check_offer_step` | `check_offer_step` | `POST /forum/offer-bids/check` | `offers bid` |
| Withdraw a bid never placed | `/offers/active` Withdraw | `withdraw_offer_bid` | `withdraw_offer_bid` | `POST /forum/offer-bids/withdraw` | `offers withdraw` |
| Read active Offers and history | `/offers/active`, `/offers/history` | `list_my_active_offers`, `list_my_offer_history` | same | same routes | `offers active`, `offers history` |

- **New names.** `get_funding_address`, `prepare_offer_bid`, `check_offer_step`,
  `withdraw_offer_bid`, their routes, and `offers withdraw` and `account funding` are
  proposed names. `bid_on_offer_slot` gives way to the prepare and check pair.
- **Withdraw.** Withdraw asks Patchbay to send `withdraw` after `placeBy`. Patchbay also
  sends it for every unplaced bid on its own, and anyone may send it.
- **Card.** "Add USDC" by card is a person's step in Privy's window. The agent row is the
  address path, so this is not a person-only action.
- **Agent spending switch.** It goes away, because an agent spends its own wallet's USDC
  with its own key and never its person's.
- **Paid tools.** A bid is an ordinary approve and bid from the bidder's own wallet, not an
  x402 payment. Paid tools keep x402.

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
3. **Pages and agent surfaces.** Approve, Bid, Withdraw, Add USDC and USDC Balance on the
   five surfaces, walked at 320, 390 and 1280.
4. **Sean's go.** On his named go: deploy the contract, set the owner Safe (a multi-owner
   Safe Sean names), the operator and moderator keys, Patchbay as a site, and add the tables
   to production.
5. **Cutover release.** One release closes Credits bidding, removes the Credits code above
   and opens Offers on USDC.

## Bid path

Signed bids went, and approve then bid replaced them (HQ engineering ruling, 17:20Z).

- **The reason.** The first contract took a USDC `ReceiveWithAuthorization` signed by the
  bidder and sent by anyone. USDC checks the signature of an account upgraded with
  EIP-7702 through ERC-1271, and Privy's upgraded wallets need an undocumented ERC-1271
  signature form, so a signed bid from them could not be relied on.
  Approve and bid are ordinary calls that any account able to send a transaction can make.
- **Gaps that went with it.** The signature never covered the payout wallet; there is no
  signature now, and the payout wallet is read in the same call that takes the money.
  The holder of a signature chose the moment to send it, and a bidder could cancel one
  before it landed; neither applies to a bid the bidder sends.
- **Anyone may bid.** Bidding was never limited to the operator, and opening it to every
  caller opens nothing new:
  - a bid spends only its caller's own money;
  - a spam bid locks only the spammer's own USDC, at least the site's minimum each;
  - the operator can hand any held bid back, anyone can after `placeBy`, and `placeBy` is
    at most 72 hours away, so no bid waits longer than that.
- **Paymaster cost.** Sponsored gas for a spam bid is bounded the same way: each bid
  commits at least the minimum of real USDC, and Patchbay keeps its request limits on the
  doors that build the steps.

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
- **F6 Stray USDC.** USDC sent to the contract other than through a bid is in no record and
  never leaves. There is no sweep, so no key can take money out.

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

### HQ rulings

- The payout wallet is kept per bid (F2, F3).
- The moderator is set by the owner and is never the operator or the admin.
- The USDC token and the staking contract are refused as payout wallets (F4 b).
- `MAX_WAIT` is 72 hours, one placement length (F7).
- F4, F5 and F6 are accepted, as above.
- One bid path: approve then bid from the bidder's own account (17:20Z).
- After the second review (18:22Z): only the owner names a site's payout wallet (N1a, N1b);
  the owner must be a multi-owner Safe, with no timelock (N1c); clean-up is by replacement
  (N1d); bids already made pay their stored wallet (N2); the moderator is never the admin or
  the operator, checked in every function that sets one of them (N3). A removal still
  charges the whole bid (F1).

### Open

13. **Unused time on a buyout.** A placement replaced by a newer bid, before its time is up.
    - a) Its unused time goes back to its bidder, as the contract does today.
    - b) It pays the whole bid, as a removal does.
    - Recommendation: a. The replaced bidder broke no rule and lost the slot to a higher
      bid; with b, a new bid could cut short a placement its bidder had paid for in full.
14. **Bid path.** HQ ruled approve then bid; Sean may override.
    - a) Keep approve then bid from the bidder's own account, sponsored by the paymaster.
    - b) Return to signed bids sent by anyone.
    - Recommendation: a. Privy's upgraded wallets cannot be relied on to sign USDC
      authorizations, and the paymaster already covers the gas.
15. **F1 Full charge on removal.** A removal for policy charges the whole bid (Sean, 4 b),
    so a stolen moderator key can charge every showing bid in full, paid to the sites,
    never to the thief.
    - a) Keep it, with the moderator as a key apart from the operator.
    - b) A removal pays only the time shown, and the rest goes back.
    - Recommendation: a. It is Sean's 4 b, and the money still goes only to the sites.

## Later

- The contract deploy, the wallets, the tables in the shared production database and the
  cutover release. Each needs its own named go.
