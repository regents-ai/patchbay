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

## October 9 Bankr snapshot refresh

Sean authorized coordination with Techtree in this chat. Its owner supplied the exact published `techtree_app.wallet_bench_results` and `wallet_bench_checks` rows in `/Users/sean/Documents/regent/artifacts/techtree-release-2026-10-09/published-matrix-rows.json`, SHA256 `2f4cd356ebd5a18315e3f68362340c555da34b52a55af6cf64279b84a056db96`. The raw saved-turn export lacks published run numbers and recipe digests and was refused as input.

Appended locally, preserving the complete published records:

- Codex CLI `8179a9b5-2f42-4092-b690-86ef3963f338`: Install PASS, Make a wallet FAILED_SAFETY, both run 4.
- Claude Code `393e625b-6ac7-406c-abec-3497cbf16cd8`: Install PASS, Make a wallet INCONCLUSIVE, both run 4.
- Cline `9d05544a-054b-4bd2-9db5-cd678272c708`: Install PASS, run 4 only. No wallet result was invented.

Five result rows and 45 checks added. The snapshot now has 208 result rows. The original 203 rows retain their pre-import ordered JSON checksum `f267f255a6778a15b7fbf2b0a8c0aa53`. Repeating the exact import adds zero rows. No result was regraded, renumbered or overwritten; every original check reason, version and turn is retained. The infrastructure-only H04 attempt `624b6c96-2b20-4390-8e55-c043a4aea3bb` was not given a matrix judgment.

The display labels the recorded `model` as Coding model. Optional `versions.setup` and `versions.hosted_model` display separately when Techtree records them; the imported source does not contain these fields. The existing source summaries and criteria disclose supplied accounts and authorized credits. Techtree separately confirmed H10/H05 had an owner-supplied benchmark account and prepaid LLM credits with Bankr Max Mode `gemini-3.8-flash`; H06 only installed the CLI and received no Bankr key or hosted calls. This confirmation remains a handoff fact, not an alteration of source records. No hosted-call cost was estimated or published.

The one-off `/Users/sean/Documents/regent/artifacts/patchbay-bench-board-local-1009/refresh_snapshot.exs` uses an Ecto/PostgreSQL transaction, explicit `127.0.0.1:5432`, local role `sean`, and only `patchbay_bench_board_1009`. It rejects an existing Repo or started Patchbay application, pins the reviewed export hash, aborts conflicting records, and checks historical preservation. Run only with `mix run --no-start`. `rehearsal-not-for-import.json` is marked and refuses apply; its synthetic run numbers and absent versions were used only in rolled-back rehearsals. An altered check value was refused by the hash guard. Astra's initial inherited-connection and unpinned-input findings were corrected before retaining the helper; the initial successful import had already occurred when that review arrived, and independent local SQL confirmed its contents and unchanged history.

Verified: scoped compilation/format, unchanged four-wallet filters and 36/32 squares, Cline Install-only, nine criterion IDs, prior edge cases, repeat import, invalid inputs, and live local Codex/Claude run 4 detail pages with original evidence/source links. Browser Install and Make a wallet show the updated tallies. Screenshots: `updated-install.jpg` and `updated-wallet.jpg` in the local artifact directory. The existing preview was not restarted. Publication, Credits changes and wallet actions remain held. Offers design is now separately complete at `68feb31`.

Astra's follow-up source review confirmed isolation and hash controls corrected, five original grades and 45 checks intact; it made no database queries. Patchbay independently verified database counts and historical checksum. A simulated already-running Repo was also refused before connection.
