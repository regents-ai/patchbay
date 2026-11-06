# Agent Offers in USDC on Base: design note

6 Nov 2026. Patchbay chief engineer, on HQ's order of 15:52Z relaying Sean: "drop the
credits system entirely . remove it from points, remove it from patchbay. Where they were
used in patchbay will become a pure USDC on Base system, with an onramp / deposit , and a
live contract for the offers (designed for patchbay.help but extensible to more sites in
the future, serving as a marketplace for offer inventory and demand)".

This is a design note on a branch. It changes no code, deploys no contract and touches no
production data. Every Credits balance and every open Credits bid stays exactly as it is
until Sean decides the cutover (decision 11). Building the contract, the reader and the
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

Patchbay.help is its first site, and other Regent sites can list into it later.

Patchbay keeps what it is good at: screening wordings, the slot order, the two-second
windows and choosing winners, all of which are tested today. The contract keeps the money,
under rules a stolen key cannot bend.

### Contract (Foundry, `contracts/` beside `PatchbayEscrow`)

- **Sites (venues).** The owner adds a site: its id (`keccak256("patchbay.help")`), its
  admin, its operator (the site's server key) and its payout wallet. A site's admin can
  replace its operator and payout wallet.
- **Inventory.** A site's admin lists slots, and every listing is an event. Each slot
  carries:
  - its market (a site market or Global);
  - its opening minimum, in USDC base units;
  - its placement length, 72 hours on Patchbay.
- **Demand.** `bid(site, slot, lane, wordingHash, amount, placeBy, permit)` pulls `amount`
  USDC from the bidder into the contract in the same transaction.
  - One USDC permit signature and one transaction, with no standing allowance.
  - It is refused below the slot's opening minimum, for an unlisted slot, or while new bids
    are paused.
  - `wordingHash` binds the bid to the exact Offer version Patchbay screened.
- **Operator steps.** Each step is bounded by the contract:
  - `place(bidId, startsAt)` turns a held bid into a placement;
  - `returnBid(bidId)` sends the whole amount back to the bidder;
  - `endEarly(placementId, reason)` ends a placement, either replaced by a buyout or
    removed for policy.
- **Money rules the contract enforces, whatever the operator does.**
  - Bid money leaves only two ways: back to its bidder, or as payment for time the
    placement actually showed.
  - Used time is `amount × shown ÷ length`, rounded down, and the bidder gets the
    remainder. Nothing is rounded twice.
  - Used time divides by a protocol share fixed at deploy (decision 3). That share goes to
    REGENT staking through `depositUSDC`, and the rest goes to the site's payout wallet.
    Both accrue and are paid out by an open `pushRevenue` and `payOut(site)`, so a paused
    staking contract never holds up a bidder.
  - After `placeBy`, a bid that was never placed can be withdrawn by its bidder alone,
    with no operator needed. After `startsAt + length`, anyone may finish a placement.
  - There is no sweep, no owner withdrawal and no ETH.
- **Stolen operator key.** A thief can do three things, and cannot take any money:
  - return bids;
  - place held bids early, which still charges only for shown time;
  - pay that time to the site's payout wallet.
- **Events.** One event per change:
  - `SiteAdded`, `SiteChanged`, `SlotListed`, `SlotChanged`;
  - `BidPlaced`, `BidReturned`, `BidWithdrawn`;
  - `Placed`, `Ended` (with `returned`, `used` and the reason);
  - `RevenuePushed`, `PaidOut`, `Paused`.
- **Checks.** `forge build`, `forge fmt --check`, `forge test` with fuzzed splits (returned
  + used always equals the bid, for every time and amount) and invariant tests (the
  contract's USDC always equals held + placed + accrued), `slither`, and a fork script on
  real Base USDC that is never broadcast, as `Sanity.s.sol` does.

### Funding a wallet (the onramp and deposit path)

- **A person** pays from their own Privy wallet. Its **USDC Balance** is read live and is
  shown in the account menu where Credits sit today. Add USDC opens two ways:
  - **Card**: Privy's card window, already live, puts USDC on Base into that wallet.
  - **Send**: the wallet's full address, with a copy icon and a QR code, for USDC on Base
    from an exchange or another wallet.
- **An agent with its own wallet** is funded by its person, or by anyone, sending USDC on
  Base to its address. Card purchases need a person in the browser, so an agent cannot buy
  by card for itself.
  - The agent reads its USDC Balance through `account_balances`, which gains a `usdc`
    field.
  - Its own key signs its permit and sends its bid. The site prepares the step and never
    holds the key.
- **No balance is kept by Regents.** Money sits in the wallet until a bid commits it to the
  contract. Committed money is shown apart, as "In Offers", beside the USDC Balance.
- **Gas.** A person who bought USDC by card holds no ETH (decision 7).

### Reading the chain (chain-events)

- **Reading job.** One AshOban reading job for RegentOffers on Base, unique by contract.
  It runs a pass and snoozes five minutes, and it snoozes 60 seconds when the node does not
  answer. A watch on the Oban cron makes sure the job exists.
- **Cursor.** One cursor row holds the first unread block, the head last seen and
  `rescan_from`.
- **Each pass:**
  - reads at `latest`;
  - re-reads the newest 300 blocks (one minute on Base);
  - reads forward in stretches of up to 10,000 blocks, halving a stretch the node
    refuses;
  - reports `[:patchbay, :indexer, :lag]`, which becomes Sentinel's
    `health_indexer_lag_blocks`.
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
- **Reading early.** A confirmed press (`OnchainSteps.checked/3`) and the read-again icon
  bring the next pass forward to ten seconds away (`ChainRefresh.request/1`), at most once
  every ten seconds. The press's own receipt is read every quarter second for the button's
  words.
- **Catching up.** A notice shows when the head was read over 420 seconds ago, or when the
  record is over 3,000 blocks behind it.
- **Model.** The model is Keyfleet's reader. Patchbay's escrow reads (`Patchbay.Escrow.Watch`,
  per-report polling) stay as they are.

### Buttons

Bid follows `onchain-buttons`:

- The server builds the permit and the bid step. Every press reaches the wallet, including
  a repeat press while one is pending, and a duplicate bid is an accepted outcome: the
  server returns the extra in full.
- Bid is disabled only when the chain makes it certain to fail, read at the latest block:
  - "Below the slot minimum";
  - "Not enough USDC";
  - "Bids paused";
  - "Slot not listed".
- The 110% replacement rule and the wording screen are Patchbay's server rules, not the
  chain's. A bid under them lands, is returned in full, and the page says why.

### Agent surfaces

Every action reaches one server door, through five surfaces:

- the website in a headless browser;
- WebMCP;
- hosted `/mcp`;
- the signed HTTP route;
- the regents CLI.

Each surface carries the same words and refusals. Steps the operator signs (place, return,
end, list) are the site's server, not an account owner's action.

| Action | Website | WebMCP | /mcp | HTTP | CLI |
| --- | --- | --- | --- | --- | --- |
| Read USDC Balance and In Offers | account menu, `/account` | `account_balances` | `account_balances` | `GET /tools/account/balances` | `account balances` |
| Add USDC | Add USDC: card window, or address and QR code | `get_funding_address` | `get_funding_address` | `GET /tools/account/funding` | `account funding` |
| Read slots and bid options | `/offers`, `/offers/bid` | `list_offer_slots`, `get_offer_bid_options` | same | same routes | `offers slots`, `offers bid-options` |
| Prepare a bid (permit and step) | `/offers/bid` Bid | `prepare_offer_bid` | `prepare_offer_bid` | `POST /forum/offer-bids/prepare` | `offers bid` (signs and sends with the agent's key) |
| Report a sent bid | the hook reports the hash | `report_offer_bid_sent` | `report_offer_bid_sent` | `POST /forum/offer-bids/sent` | `offers bid` |
| Withdraw a bid never placed | `/offers/active` Withdraw | `prepare_offer_withdraw` | `prepare_offer_withdraw` | `POST /forum/offer-bids/withdraw/prepare` | `offers withdraw` |
| Read active Offers and history | `/offers/active`, `/offers/history` | `list_my_active_offers`, `list_my_offer_history` | same | same routes | `offers active`, `offers history` |

- **New names.** `get_funding_address`, `prepare_offer_bid`, `report_offer_bid_sent`,
  `prepare_offer_withdraw`, their routes and `offers withdraw` / `account funding` are
  proposed names. `bid_on_offer_slot` gives way to the prepare and report pair.
- **Card.** "Add USDC" by card is a person's step in Privy's window. The agent row is the
  address path, so this is not a person-only action.
- **Agent spending switch.** It goes away, because an agent spends its own wallet's USDC
  with its own key and never its person's.
- **Paid tools.** A bid is not an x402 payment: it is a contract call that the agent sends
  itself. Paid tools keep x402.

## Credits leave Patchbay (hard cutover, after decision 11)

One release removes everything below, with no Credits branch kept:

- the Buy Credits panel, `credits.ts`, `CreditsLimit` and the Credits row and card;
- `Patchbay.Credits`, `Offers.Holds` and `CreditAmount`;
- `account_credits_history` and its CLI command;
- the Credits fields in `account_balances` and `get_offer_bid_options`;
- the `regent_credits` config and dependency;
- the Credits walks and tests;
- the feature-map and parity rows, and every guide's Credits words.

Credits help stays only as long as decision 12 needs it. Points drops its "Credits
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
   key, Patchbay as a site and its slots, and add the tables to production.
5. **Cutover release.** One release, carried out as decision 11 says.

## Decisions for Sean

1. **Custody.** Where a bid's money sits until it settles.
   - a) In the contract, from the bid until it settles, as Credits are held today. A bid
     is always good for its amount, and a bid that loses comes back without anyone acting.
   - b) Pay when it wins: the bidder leaves a permit, and the contract pulls the money only
     when the bid is placed. The money stays in the wallet longer, but a bid can fail when
     it wins because the money was spent meanwhile.
   - Recommendation: a. A winning bid that cannot pay breaks the slot order, and a) keeps
     today's tested market behaviour.
2. **Funding a bid.** How the money reaches the contract.
   - a) Each bid pulls from the wallet with one USDC permit signature and one transaction.
     Regents keeps no balance for anyone.
   - b) A deposit balance inside the contract that bids draw from and that can be withdrawn
     at any time. This is closer to Credits, but it is a balance Regents' contract keeps.
   - c) Approve, then bid, in two transactions.
   - Recommendation: a. It is the fewest steps, it keeps the payments rule that Regents
     keeps no USDC for anyone outside a committed escrow, and an agent does it with its own
     key in one call.
3. **Fees and their receivers.** How the money for shown time divides.
   - a) 10% to REGENT staking and 90% to the site's payout wallet (for patchbay.help, the
     Regents Labs treasury Safe), fixed at deploy.
   - b) All of it to REGENT staking.
   - c) All of it to the Regents Labs treasury.
   - Recommendation: a. It matches the priority-report escrow's 90/10, and it gives a
     future site a reason to list.
4. **Refunds and disputes.** What happens to unused time on a removal for policy, and how
   disputes are handled.
   - a) The unused time goes back to the bidder. Disputes are handled by the team off the
     chain and paid from the treasury, and the contract never reverses a payment.
   - b) The unused time is forfeited to the site, as today, with disputes handled the same
     way as a).
   - Recommendation: a. Real USDC taken by an operator's removal invites disputes, and a)
     means a stolen operator key cannot cost a bidder anything but shown time.
5. **Listing.** Who may list slots.
   - a) Only sites the owner adds, Regent sites first.
   - b) Anyone, with a listing bond.
   - c) Anyone.
   - Recommendation: a. Screening and policy are each site's own, and opening listing
     later is a new contract version (decision 8).
6. **Onramp provider.** How a person buys USDC by card.
   - a) Privy's card window, already live (Stripe or MoonPay), plus the send-to-address
     path.
   - b) Add Coinbase Onramp as a second card path.
   - c) Coinbase only.
   - Recommendation: a now, b once a test purchase shows where Privy's window does not
     reach.
7. **Gas for people.** A person who bought USDC by card holds no ETH to send a bid.
   - a) Patchbay sponsors gas for Privy embedded wallets through Privy, and agents pay
     their own.
   - b) Everyone pays their own Base ETH.
   - Recommendation: a. Without it, a card purchase alone cannot bid.
8. **Upgrades and pause.** Whether the contract can be upgraded or paused.
   - a) No upgrade. The owner Safe can pause new bids and new listings only; returns,
     withdrawals, finishing and payouts never pause.
   - b) Fully fixed, with no pause, like `PatchbayEscrow`.
   - c) An upgradeable proxy.
   - Recommendation: a. It can stop new money coming in during an incident without ever
     trapping money already in, and a new version is a new contract that sites move to.
9. **Owner and operator keys.**
   - a) The owner is Sean's Safe, and the operator is a new key used only for Offers.
   - b) The operator reuses the escrow's operator key.
   - Recommendation: a. One key per contract keeps a leak to one market.
10. **Auction rules.** Where the market's rules live.
    - a) Patchbay's server keeps the windows, the 110% rule and the screening, and the
      contract checks only the slot's opening minimum and the money rules.
    - b) The contract runs the whole auction.
    - Recommendation: a. The rules are tested today and change by release, while the money
      stays safe either way. b) can come in a later version.
11. **Cutover of open Credits bids.** What happens to Credits bids and placements on the
    cutover day.
    - a) In the cutover release, every waiting Credits bid is given back in full, and every
      showing placement ends as a buyout with its unused time returned in Credits. Offers
      reopen on USDC in the same release.
    - b) No new Credits bids, and showing placements run out on Credits for up to 72
      hours, so two systems run for three days.
    - c) As a), and every returned Credit is also paid out in USDC (see decision 12).
    - Recommendation: a. It is a hard cutover with nothing left running on Credits, and no
      bidder loses unused time.
12. **Leftover Credits balances.** This is shared by all five sites, so it is HQ's and the
    template's to run.
    - a) Each account's remaining Credits are paid out 1:1 in USDC to its main wallet from
      the treasury, and Credits then close everywhere.
    - b) Balances are paid out on request through Credits help for a set time.
    - Recommendation: a. Credits were bought with USDC, so paying them back is the clean
      end, and Credits help can then go.

## Not decided here

- The count of live Credits balances and open bids. That is a production read and waits
  for Sean's named go.
- The contract deploy, the wallets, the tables in the shared production database and the
  cutover release. Each needs its own named go.
