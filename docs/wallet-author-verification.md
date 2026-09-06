# Wallet-author verification

Central ticket `regent-qht.28.21` implements the bounded autonomous author path
in [the CLI guide](../cli/docs/wallet-author.md). No deployment, live wallet transfer,
provider login or source retirement was performed.

Verified locally:

- 468 full platform tests passed. Six affected tests passed after the final request
  validation refinement and the additional chunked-body case.
- Nine CLI tests passed, including packed installation, external signature binding,
  altered-input refusal, unknown HTTP outcomes and no automatic retries.
- 128 browser hook tests and the public CLI/browser adapter parity test passed.
- Three CLI-to-HTTP journeys passed against the actual local SIWA service: wallet
  nonce/signature verification, durable request replay refusal, body binding,
  report preparation/payment/publication, receipt recovery and valid second-wallet
  ownership denial. Facilitator and chain RPC were loopback fixtures with synthetic
  keys. This does not establish real settlement or chain confirmation.
- Same-address human and autonomous profiles remain separate. Wallet authors have
  no Privy subject/human name, cannot become browser profiles or send tips, and
  remain refused after suspension. Cookies confer no signed-agent authority.
- Changed, missing, chunked and oversized bodies were exercised through HTTP.
  Payment signatures are covered by the body digest and filtered from parameter
  logging. Broker requests exclude unrelated browser headers.
- Migration rehearsal preserved all existing profile fields, rejected invalid
  wallet shapes and refused rollback with autonomous rows. Safe rollback/up and
  identical rerun preserved records; cleanup removed only owned UUID fixtures.
- Compilation with warnings-as-errors, unused dependencies and changed-file
  formatting passed. Eight pre-existing Credo findings and five unrelated formatting
  failures remain; the whole precommit command is not green.
- A production-mode macOS Mix release built with staged pinned shared packages.
  A Linux image and running production release remain unverified.

Use Control's prepared isolated worktree with its unique database. From platform,
run `mix test`, or the two files under `test/patchbay_web/controllers/payments_api/`
named `wallet_author_test.exs` and `wallet_journey_test.exs` for the focused checks.
From CLI run `npm run check` and `npm run test:parity`; from platform/assets run
`npm test`. The CLI guide explains the optional actual local SIWA service run.
Only disposable databases, synthetic wallets and loopback services are appropriate.

Exact hashes, dependency snapshots and output logs are in the workspace artifact
`artifacts/foundation-rollout/regent-qht.28.21-inputs-v1.json` and its bound independent
review. The parent remains open for production/provider acceptance.
