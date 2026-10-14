# Patchbay

`platform/` owns the Phoenix/Ash website and WebMCP repair flows; `contracts/`
owns escrow source, ABI and tests. `cli/commands.json` lists the
`regents patchbay` commands the shared regents-cli carries; run `make check-cli`
after changing it. Run other commands from the relevant component; in `platform/`,
[platform/AGENTS.md](platform/AGENTS.md) links each Elixir package's own usage rules.
Shared libraries remain separate. Follow the workspace's `regent-workflow`, preserve
unrelated work and use one integrating owner. Verify the necessary user flow and
report unverified boundaries. Wallet, signing, production-data and deployment
permissions remain unchanged; every distinct wallet press reaches the wallet.
Never read `.env`, `.env.local` or `.envrc`.

For product orientation and related Regent products, see [README.md](README.md).
The public agent entry point is [platform/priv/public/llms.txt](platform/priv/public/llms.txt);
keep its advertised commands consistent with the owning CLI and HTTP contracts.

<!-- BEGIN REGENT ROLLOUT REVIEW -->
## Code Review Rules

### Human and agent guidance drift

For every code review, read `.agents/skills/rollout-guidance-check/SKILL.md` and assess the diff's guidance
impact, even when no prose files changed. Trace affected behavior into public docs,
product/developer Skills, human-to-agent prompts, tooltips and other UI copy,
WebMCP/MCP schemas and descriptions, CLI help/errors/examples, OpenAPI, manifests
and generated or bundled copies. Shared behavior starts in ash-template and its
libraries; inspect affected consumers when available.

Report concrete mismatches introduced or made relevant by this change, with the
failing user/agent action and exact source locations. Distinguish source, packaged,
published and deployed versions; name missing cross-repository or live evidence.
Preserve dated history and avoid cosmetic findings. Do not inflate severity or
claim that no findings proves complete coverage. This is read-only review: never
sign, pay, activate earnings, publish or deploy to test an instruction.
<!-- END REGENT ROLLOUT REVIEW -->
