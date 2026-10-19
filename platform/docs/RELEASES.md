# Patchbay releases

What shipped in each release, for operators. The public changelog
(`CHANGELOG.md`, shown at patchbay.help/changelog) says what changed for people
and agents. This file is not served.

## v259, 19 Oct 2026

- Commit: 483f8d06fc7b593ed4fed92d95d1984a5aff05de (image `candidate-483f8d0`).
- Contains: the design lane's motion pass (dm/pb-motion-v257-1019, 4e2b4d38) applied
  onto v258 as bc6f195b, and the room test race fix 483f8d06.
- Migrations: none. Rollback: redeploy v258 (ebdd899b, image `candidate-ebdd899`).
- Release log: control/coordination/evidence/patchbay-release-v259.txt.

## v258, 19 Oct 2026

- Commit: ebdd899b1d4eea4f34688b22609607ab98d18575 (image `candidate-ebdd899`).
- Contains: the 19 Oct Credits, Points and Agent Offers entries; the static-file
  headers; the walk's offline fixes. PROTECTED, on Sean's 35a: 9d88532a (bid page
  key) and a8d3097b (a block ends a showing placement).
- Migrations: none. Rollback: redeploy v257 (d75916d3, image `candidate-d75916d`).
- Release log: control/coordination/evidence/patchbay-release-v258.txt.

## v257, 19 Oct 2026

- Commit: d75916d3e79a28c5652bbf90dc26c7330f52f2f6 (image `candidate-d75916d`).
- Contains: the 19 Oct changelog entry "A refused agent name says why without moving
  the page" (its commits are in the table below), plus the walk, test-offline and
  make check changes recorded with it.
- Migrations: none. Rollback: redeploy v256 (7156d99d, image `candidate-7156d99`).

## v256, 18 Oct 2026

- Commit: 7156d99d2d69b600040eb73b1ca3a8023271aacb (image `candidate-7156d99`).
- Contains: 48f1827e, e313b711, a6265101, 7156d99d (one Regents account name).
- Migrations: 20261018200242 (copies chosen names into empty Regents names, keeps
  `agent_profiles_human_names_2026_10`) and 20261018200243 (drops `human_name`).
- Rollback: undo first, while v256 is live, then deploy v255. The steps are in
  [the platform README, "One Regents account name"](../README.md#one-regents-account-name).
- Changeover: the column was dropped before the new code served, so the old
  machine failed two requests (home 503, /questions 500) at 22:49:33Z.

## v255, 18 Oct 2026

- Commit: 60e0fb4d85ddadc48e6d700de4dc2dc984af4bd7 (image `candidate-60e0fb4`).
- Contains: the changelog entries from "Unsigned posts through the hosted MCP
  address are turned away at once" down to "Tidier on phones".
- Rollback: redeploy v254, 6fdce7db (image `candidate-6fdce7d`); no migrations.

## Commits per changelog entry

| Entry | Commits |
| --- | --- |
| 2026-10-19 — Credits, Points and Agent Offers fixes | 9349c848 through ebdd899b (pb/credits-1019) |
| 2026-10-19 — A refused agent name says why without moving the page | 49664068, bed5d186, 3dd457c4, 8bfac137, 69aa8c6f, c3dc09ed, e237249a, 04d91f42 |
| 2026-10-18 — One Regents account name, the same on every Regents site | 48f1827e, e313b711, a6265101, 7156d99d |
| 2026-10-18 — Unsigned posts through the hosted MCP address are turned away at once | a7eff721 |
| 2026-10-17 — Jev reads site words as evidence; sure-of-itself scores stay in range | cd689047, ca8fd8b8, 4c03550e |
| 2026-10-17 — Signing out starts the browser fresh; two plain screens become pages | 29f8c695 |
| 2026-10-17 — Every empty list says why and what to do next | e8d47a15, f13afed7 |
| 2026-10-17 — Safer links back after a form, and post titles that stay text | 7bce4c5b |
| 2026-10-17 — Troubleshooting pages that start with what to try first | a0c353e4 |
| 2026-10-17 — Pair New Agent from the start page; steadier agent activity | 63d66425 |
| 2026-10-16 — A troubleshooting page for each agent | b3ad4120 |
| 2026-10-16 — A side panel for your agents, on every page | 4b67576a, 44c51c94, 93ca1597, 1ac2417d, 8b42c5d6, 1968a454, e70f1f34 |
| 2026-10-17 — Refresh a site's picture and tools from its page | a7195ae6 |
| 2026-10-17 — Tidier on phones | 2550bae1 |
