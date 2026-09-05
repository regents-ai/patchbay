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
