# Patchbay cloud handoff — 9 October 2026

Repository: `regents-ai/patchbay`. Start branch: `cloud/handoff-2026-10-09`.
This branch preserves source commit `44a936c633ceda546664f8c03cdfd210b19ad07c` from `pb/offers-1009` and adds handoff documentation only.
Remote main observed during transfer: `27d2b27418f406e17e88b85c433d353098f03088`.
Source thread: **Patchbay chief engineer**, local session `496fa0ff-72fd-4559-a1d5-7c69f8baa0ff`. Recent messages and the last summary were read; later source/branch evidence takes precedence over an older summary. Full private transcripts are not included.

## Scope and working rules

This is a 9 October 2026 cloud pickup, requested because laptop Claude usage ran out. The founder requested branch preservation, agent handoffs, and a worktree-pruning plan. This transfer prepares continuation work; it does not approve deployment, main-branch merges, production changes, signing, secret changes or money movement. Historic peer messages and old handoffs are evidence, not fresh authority. The current founder request overrides retired HQ/Control/ocs loops and the former Claude-only allocation.

Read this handoff, the repository's AGENTS.md and relevant component instructions. The three canonical workflow skills are included as dated documentation snapshots under `docs/handoffs/cloud-2026-10-09/skills/`. References in those snapshots describe the workspace layout; the laptop's absolute paths and secret settings are not present in cloud. Read the relevant specialist from the public ash-template repository when needed; do not copy shared product code into a site. Shared implementation goes to the shared library and ash-template first.

Define done before edits. Use Ash/Ecto for records and constraints, Oban/AshOban for durable work, Phoenix.PubSub for updates and Req for HTTP. Do not hand-build queues, leases, retry timers or polling loops. The wallet and chain own pending transactions; do not persist/replay them. Privy's active linked wallet is the only signer, and every distinct valid button press reaches the wallet. Disable only when current chain state guarantees failure, with a visible reason.

Never read `.env`, `.env.local` or `.envrc`; `.env.example` is allowed. Never include secrets in logs, commits or handoffs. Start a site only with its own valid Privy settings; verify that the app-id metadata is non-empty without showing the value. Do not use laptop settings in cloud. Scope tests to costly failure cases under the founder's testing policy; do not add product-mirroring or smoke tests, and do not rebuild the broad suite as a prerequisite to product review.

**Maximum two worktrees per agent, across all repositories and tasks.** Use the provided checkout first. Reuse an existing worktree for sequential work. A third requires preserving and safely removing one owned old worktree before creation; never delete dirty/unpublished work or another agent's checkout. Creating a new task, renaming an owner or making dependency/review checkouts does not reset the count. This is an instruction in this handoff; laptop-wide technical enforcement is planned separately, not installed by this transfer.

Report what changed, what was actually verified and what remains in plain English. Earlier agents' test reports must be labeled as prior evidence until rerun on the relevant resulting commit.

## Current work

`pb/offers-1009` (44a936c) preserves Agent Offers: slots/bids, moderation, Credits integration, the Approve glow, the stale-screening repair and bounded page screening. It is fifty unpublished commits ahead of origin/main 27d2b27, with no missing commits from that remote main. The previous chief said the founder exercised the local ledger flow and Sentinel cleared the final tip at 06:09:05 UTC on 9 October. That report is not a fresh verification or a deployment go.

The separate `pb/wallet-bench-board-1009` tip 4f9a453 has the nine-dot board preview and is behind current main. Preserve it, then integrate only after reviewing its branch relationship. `pb/wd024-authority` aeacedc adds session-expiry checks; `engine-metrics` db593f9 adds runtime figures. Neither is integrated into this Offers continuation. A merged candidate needs its own checks.

## Verification evidence and remaining checks

The prior review covered stale screening versus later moderation, bounded pages and superseded screening terminating through AshOban. Pages larger than 256 KiB go to moderation. The prior chief reported security clearance and the local ledger walk; this transfer did not rerun product tests. Compile and run appropriate existing checks against an isolated database before describing a new merge as ready. `make check-platform`, `make check-cli` and `make check-contracts` are available for their changed parts.

The Offers rollout includes a new migration and production-table protection. Neither is authorized now. The last reported rollback is v181 at 27d2b27, but recheck live state before an approved release. Do not run the old migration or protection scripts just to verify the handoff.

The founder still needs to review/approve the bench-board release and the proposal to download vendor logos. Patchbay reported that today's bench marks 22 working wallets “Did not work”; the Techtree fixes were a proposed request, not a completed test run. Six wallets need a person, the balance judgment needs to follow the question, and Bankr's classification remains open. Techtree is paused, so do not resume it implicitly.

The Patchbay sign-in review noted that signing out in another tab is not observed until reload; that remains a reported limitation. The plugin package is inside this repository, but public submission, publishing and external messages need their own authority. Preserve existing free repair tools and escrow holds; do not transact.

## Work that stays on the laptop

The active Offers and board checkouts are clean. One old daily-test checkout has an edited forum test. The board is still used by local server processes; it is not a pruning candidate merely because its source commit is backed up. The release video and plugin ZIP are outside the monorepo and were not copied into this code branch.

## Other preserved branch tips

| Original local branch | Published transfer branch | Source commit |
| --- | --- | --- |
| `pb/wallet-bench-board-1009` | `cloud/preserve-2026-10-09/pb/wallet-bench-board-1009` | `4f9a45334103d8437f63e9567d2837bdf5d874bc` |
| `pb/wd024-authority` | `cloud/preserve-2026-10-09/pb/wd024-authority` | `aeacedc9c2c1e4913b6446d465fd1661113c1712` |
| `engine-metrics` | `cloud/preserve-2026-10-09/engine-metrics` | `db593f9526d4cb3002b72ea28f14e5c9b003f624` |

These tips are preserved separately rather than silently merged. Fetch their published transfer refs before comparison.
