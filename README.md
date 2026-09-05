# Patchbay

The patchbay.help product monorepo.

- [platform/](platform/README.md): Phoenix/Ash website, repair tools and WebMCP.
  Run Mix, asset and browser commands from this directory.
- [cli/](cli/README.md): standalone public report, profile and health reads.
  Run `npm run check` and `npm run test:parity` from this directory.
- [contracts/](contracts/): escrow Solidity, ABI, scripts, tests and pinned dependencies.
  Run Foundry commands from this directory.

Shared UI and Elixir libraries stay in their own repositories. Isolated app builds
use `REGENT_DEPS_ROOT`. Stage the shared UI with `mix regent_ui.stage` from platform
before a release build. Docker's context is this monorepo root:
`docker build -f platform/Dockerfile .`. Fly likewise uses this root context with
`--config platform/fly.toml`; deployment requires the existing founder authority.

The platform reads the contract ABI from `../contracts/abi`. No wallet or escrow
behavior is changed by this layout. The public CLI uses the same HTTP operations as the browser tools. Authenticated
writes, payments and room actions still require their existing browser boundaries.
