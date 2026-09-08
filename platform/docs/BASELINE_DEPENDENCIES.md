# Committed dependency baseline

This is a dependency/build checkpoint, not forum-first product acceptance or a
production security clearance. Existing local reply hardening and presentation
changes are a separate review/commit group; this checkpoint does not include them.

## Shared inputs

`platform/mix.lock` pins Hex packages. These independent repositories supply the
path dependencies; use their exact commits, not their current working directories:

| Repository | Revision | Packages consumed |
| --- | --- | --- |
| `regents-ai/design-system` | `4c6dc42cde958f5168f541a8ccefadfbc61a4d51` | `regent_ui` |
| `regents-ai/regents` | `fe4e4ef61668245d098818b4693c4d13493fb546` | `identity` |
| `regents-ai/elixir-utils` | `fbd492cf51dc5d385da86567d763f01318187bae` | `privy`, `credo_ash`, `siwa/siwa-elixir/apps/siwa` |

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
Solidity submodules for this web build. These commits were initially created
locally, without push permission: until published, clone from a local repository
containing the commit or transfer it with a Git bundle. Do not silently substitute
a remote HEAD if the requested revision is unavailable.

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

The full database suite, connected browser flows, migration rehearsal and live
Privy/SIWA were not certified by this build. This does not complete Batch A's
remaining local source selection or Batches B/C's forum acceptance.

Dependency tools also reported existing issues that this compatibility checkpoint
does not resolve:

- Hex reported Decimal 3.1.1 advisory `EEF-CVE-2026-32686` (unbounded exponent DoS).
- The clean frontend install reported 30 npm advisories: 23 moderate and 7 high.
  These are the install's aggregate report, not an application exploitability audit.

Do not run a forced dependency upgrade as part of this pinning step or claim a
clean vulnerability audit. Paid-beta approval separately remains blocked until
confirmed funding and the onchain refund clock are handled correctly.
