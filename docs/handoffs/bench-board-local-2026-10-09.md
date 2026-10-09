# Bench board local preparation — 9 October 2026

Sean asked Patchbay's Codex chief to take over Claude's work and prepare the bench board locally. Astra watchdog: `01a11974-835f-7bf3-8b7d-a0d5549904f5`. Sean authorized direct review messages. Techtree's chief relayed Sean's request to remove placeholder columns from both charts and remove Cline from Make a wallet; its user messages were independently checked.

Done means a configured local preview, preserved recorded runs, the requested filtering, usable desktop/phone navigation, and passing scoped build checks. These checks are complete.

## Source

- Worktree: `/Users/sean/Documents/regent/worktrees/patchbay/bench-board-local`.
- Branch: `pb/bench-board-local-1009`, based on main `27d2b27418f406e17e88b85c433d353098f03088`.
- Original board `4f9a45334103d8437f63e9567d2837bdf5d874bc` cherry-picked as `1a78c168561a74556e6684e57ab63a05808fffaa`.
- Follow-up changes hide only never-attempted participants whose fixed reasons are WAITING_HUMAN/NOT_RUN. Wallet filtering spans both charts; row filtering is per chart. Unknown cells and actual attempts remain. HTML and Markdown agree; pair pages retain the original roster.
- Empty-board rendering, shared reason display, Pixel headings and distinct dot fills were repaired. Astra confirmed WD039's remaining forced-colors outline cascade issue resolved in source. Forced-colors browser legibility was not independently exercised.

## Preview and checks

Preview: `http://localhost:4006/wallet-bench` and `?test=wallet`. Patchbay's own approved direnv settings are loaded; nonempty Privy metadata checked without printing values. No sign-in or wallet transaction was performed.

Isolated database `patchbay_bench_board_1009` copies the existing local October 7 snapshot, not production. It holds 203 recorded runs. Four wallets remain: Bankr, MoonPay, Foundry Cast, Zerion. Install has nine agents/36 squares; Make a wallet has eight agents/32 squares. Cline remains in Install. All 203 attempts and nine check IDs per tested square remain. Actual waiting-for-human attempts are retained.

Passed: compile with warnings treated as errors, scoped format check, assets build, TypeScript checks, whitespace check. One-off driver checked recorded-run preservation, empty/all-excluded boards, unknown participants, mixed blockers, actual WAITING_HUMAN attempts and visible additional reasons. Its initial standalone render setup failed; it was corrected to use a standard Phoenix endpoint and rerun successfully. No behavioral suite was added or expanded.

Browser: both tabs, pair loading (six runs), keyboard Enter, Escape, Close, Back/Forward, and 390px phone layout exercised. Page width stays 390px; the board scrolls inside its region. Hidden participant detail pages still answer 200; unknown test answers 404. HTTP Markdown contains the same four wallets and Cline only in Install.

Local drivers and screenshots: `/Users/sean/Documents/regent/artifacts/patchbay-bench-board-local-1009/` (`serve.exs`, `check.exs`, `install-desktop.jpg`, `wallet-desktop.jpg`, `wallet-phone.jpg`). Driver disables application background writes/jobs and escrow, migrates only the isolated local database, and serves port 4006. Other servers and source snapshot were preserved.

## Remaining

Founder product review and separately authorized release. Nothing pushed or deployed. The candidate still pins Ash 3.34.4; tracked advisory GHSA-xj24-8f5c-pp5p requires a separately verified dependency update before release. This branch contains the board redesign plus the filtering, so it is not a claim that a narrow filter-only release is cleared. Offers remains preserved separately on `pb/offers-1009` at `44a936c633ceda546664f8c03cdfd210b19ad07c`; its historical checks were not rerun here.
