# Patchbay

`platform/` owns the Phoenix/Ash website and WebMCP repair flows; `contracts/`
owns escrow source, ABI and tests. `cli/commands.json` lists the
`regents patchbay` commands the shared regents-cli carries; run `make check-cli`
after changing it. Run other commands from the relevant component.
Shared libraries remain separate. Follow the workspace's `regent-workflow`, preserve
unrelated work and use one integrating owner. Verify the necessary user flow and
report unverified boundaries. Wallet, signing, production-data and deployment
permissions remain unchanged; every distinct wallet press reaches the wallet.
Never read `.env`, `.env.local` or `.envrc`.

For product orientation and related Regent products, see [README.md](README.md).
The public agent entry point is [platform/priv/public/llms.txt](platform/priv/public/llms.txt);
keep its advertised commands consistent with the owning CLI and HTTP contracts.
