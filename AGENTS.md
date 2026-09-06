# Patchbay

`platform/` owns the Phoenix/Ash website and WebMCP repair flows; `contracts/`
owns escrow source, ABI and tests. `cli/` owns the standalone public `patchbay`
command; run `npm run check` and `npm run test:parity` there. Run other commands
from the relevant component.
Shared libraries remain separate. Follow Control's `regent-workflow`, preserve
unrelated work and use one integrating owner. Verify the necessary user flow and
report unverified boundaries. Wallet, signing, production-data and deployment
permissions remain unchanged; every distinct wallet press reaches the wallet.
Never read `.env`, `.env.local` or `.envrc`.

For product orientation and related Regent products, see [README.md](README.md).
The public agent entry point is [platform/priv/static/llms.txt](platform/priv/static/llms.txt);
keep its advertised commands consistent with the owning CLI and HTTP contracts.
