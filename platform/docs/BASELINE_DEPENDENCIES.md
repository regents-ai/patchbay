# Committed dependency baseline

This records the reproducible inputs for the current source, not forum-first
product acceptance or a production security clearance. Reply hardening, catalog
fixes and shared-component adoption are now committed in separate review groups.
The ordinary-question, solution and inbox milestone has not been implemented.

## Shared inputs

`platform/mix.lock` pins Hex packages. These independent repositories supply the
path dependencies; use their exact commits, not their current working directories:

| Repository | Revision | Packages consumed |
| --- | --- | --- |
| `regents-ai/design-system` | `a040cf68597de0e06b30e47e7a7e2583d2c8f54c` | `regent_ui` |
| `regents-ai/regents` | `e183c52df9f46193e66b4d7bba9d0fc5d5721685` | `identity` |
| `regents-ai/elixir-utils` | `4d534af41736b4c059395ab9ddfadeb3f239beb6` | `privy`, `credo_ash`, `siwa/siwa-elixir/apps/siwa` |

The identity revision is published on `release/patchbay-identity-ash333`; its
package tree exactly matches the tested local commit `fe4e4ef61668245d098818b4693c4d13493fb546`.
The Elixir inputs are published on `release/patchbay-shared-inputs`; all three
package trees exactly match `fbd492cf51dc5d385da86567d763f01318187bae`.
These package-only exports avoid publishing unrelated Regents history or dirty
shared-library work. The design revision is published on `main`.

The identity commit aligns its Ash constraint with Patchbay's Ash 3.33 lock.
The consumer and standalone identity configuration explicitly choose codepoint
string limits. Library configuration is not inherited by consuming applications.
The design commit preserves Pixel headings, Sans UI/body text, technical Mono,
and the current primary outline/shimmer behavior. It does not restore the older
universal rounded-box styling.

## Reproduce without a dirty sibling overlay

Use an empty build directory and ordinary Git checkouts with this sibling layout:

```text
build-root/
  patchbay/platform/
  design-system/regent_ui/
  regents/identity/
  elixir-utils/
```

Clone Patchbay at the desired consuming commit and clone each repository above
from `https://github.com/regents-ai/<repository>.git`, then use
`git checkout --detach <revision>` in each shared checkout. Do not clone recursive
Solidity submodules for this web build. Use a normal clone that fetches the release
branches above, or explicitly fetch the named branch before detaching at its
revision. Do not silently substitute a remote HEAD if a revision is unavailable.

From `patchbay/platform`, with Elixir 1.19/OTP 28 and Node/npm available:

```sh
unset REGENT_UI_PATH REGENT_IDENTITY_PATH REGENT_PRIVY_PATH REGENT_SIWA_PATH
unset MIX_BUILD_PATH MIX_DEPS_PATH
export REGENT_DEPS_ROOT="$(cd ../.. && pwd -P)"
export MIX_ENV=test
mix deps.get --check-locked
mix compile --warnings-as-errors
mix assets.setup
mix assets.build
```

Use canonical physical paths (`pwd -P`) on macOS: mixing `/var` and `/private/var`
in external Mix build/dependency paths can produce broken relative include links.
The commands above build without starting PostgreSQL or making wallet/model calls.
For database checks, use an owned disposable `MIX_TEST_PARTITION` and the existing
`mix precommit` alias; check local PostgreSQL connection capacity first. Do not
stop another application's server to make room. No production database, signing,
payment, publication or deployment is part of this checkpoint.

## Verification and remaining limits

The selected Patchbay dependency candidate built in an empty directory using only
Git-exported shared commits: locked dependency resolution, warnings-as-errors
application compilation, asset installation and asset compilation passed. No
working-tree identity or private source overlay was used. The shared UI's existing
`mix check` passed; existing visual assertions were aligned with the documented
Sans/interaction contract rather than expanded into a new suite.

The later integrated release candidate passed `mix precommit` (490 tests, no
failures, formatter and strict Credo), `mix ash.codegen --check`, asset setup/build,
128 JavaScript checks, nine CLI checks and one CLI/browser parity check. It used
an owned disposable PostgreSQL server on a separate port, not the shared local
database. No new behavioral suite was added. The current local directory rendered
the shared frame/cards and Sans text without desktop horizontal overflow; its
theme toggle switched successfully. This is not authenticated-browser acceptance.

## Live deployment gate

Live preflight found `DATABASE_DIRECT_URL` absent from the existing Fly app's
secret names. `Patchbay.Release.migrate/0` requires that explicit migration-owner
connection; `DATABASE_URL` is deliberately not a fallback. Configure the direct
connection securely before deployment, then verify migration/schema prerequisites
and stage the pinned packages in a clean release checkout. Do not paste credentials
into repository documentation or skip the release migration command.

The public app remained on release v49 at preflight, with health reporting database
OK and migrations current. Source pushes are not evidence of a new live release.
Production migration rehearsal and live Privy/SIWA/payment flows remain unverified.

Dependency tools also reported existing issues that this compatibility checkpoint
does not resolve:

- Hex reported Decimal 3.1.1 advisory `EEF-CVE-2026-32686` (unbounded exponent DoS).
- The clean frontend install reported 30 npm advisories: 23 moderate and 7 high.
  These are the install's aggregate report, not an application exploitability audit.

Do not run a forced dependency upgrade as part of this pinning step or claim a
clean vulnerability audit. Paid-beta approval separately remains blocked until
confirmed funding and the onchain refund clock are handled correctly.
