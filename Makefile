.DEFAULT_GOAL := help
.PHONY: help check check-platform check-browser check-required-fixes check-cli check-siwa-latest check-contracts release readiness
help:
	@echo "Run make check for every gate, or check-platform, check-browser, check-required-fixes, check-cli, check-siwa-latest or check-contracts for one component."
	@echo "Run make release to run every gate, then build the committed tree into an image."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
check: check-platform check-browser check-required-fixes check-cli check-siwa-latest check-contracts
# A new checkout needs nothing first: the libraries, the page packages, esbuild and the
# shared library copies the type check reads are all fetched or built here, so the
# browser walk itself fetches nothing.
check-platform:
	cd platform && mix deps.get && mix assets.setup && mix do regent_ui.assets + regent_blog.assets + regent_identity.assets + regent_agent_access.assets && mix precommit
# The browser walk (platform/assets/test/browser): pages at 320, 390 and 1280 in
# headless Chromium. Each run starts its own server on its own port and database,
# drops it at the end, and refuses every request outside this machine.
check-browser:
	cd platform/assets && test/browser/support/failed_start_check.sh && ./node_modules/.bin/playwright test
# Every site runs the same check against ash-template's current main branch, so a
# newly published required fix reaches every site's next gate. Needs `gh auth login`.
TEMPLATE := repos/regents-ai/ash-template
check-required-fixes:
	cd platform && mkdir -p _build && rev=$$(gh api $(TEMPLATE)/commits/main --jq .sha) \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/platform/scripts/check_required_fixes.exs?ref=$$rev" > _build/check_required_fixes.exs \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/security/required-fixes.json?ref=$$rev" > _build/required-fixes.json \
	&& elixir _build/check_required_fixes.exs "ash-template $$rev" < _build/required-fixes.json
# The command description check is regents-cli's own checker at the commit pinned
# here, run by uv straight from GitHub. Move the pin in a commit.
REGENTS_CLI_REV := 0e3768f5b92fe8210fb00fea0053bcb5e9c2afaf
check-cli:
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json platform/priv/public/openapi.json
# Every site is on the newest SIWA: the newest regents-cli release on PyPI (the pin
# above, the agent guide and the install lines) and the newest change to the SIWA
# library in elixir-utils. Needs `gh auth login`.
check-siwa-latest:
	scripts/check-siwa-latest.sh $(REGENTS_CLI_REV)
# The two contract libraries are pinned submodules; a fresh clone fetches them here.
check-contracts:
	git submodule update --init --depth 1 contracts/lib/forge-std contracts/lib/openzeppelin-contracts
	cd contracts && forge fmt --check && forge build --offline && forge test --offline
# The release checks and builds exactly the committed tree, so every change must
# be committed first. A failing gate stops it before anything is built.
release:
	@test -z "$$(git status --porcelain)" || { echo "Commit every change first: the release checks and builds the committed tree." >&2; exit 1; }
	$(MAKE) check
	scripts/release.sh
# Starts the local server on a free port, checks what the agent-readiness scorer
# looks for, then stops the server.
readiness:
	scripts/readiness.sh
