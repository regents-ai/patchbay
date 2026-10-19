.DEFAULT_GOAL := help
.PHONY: help check check-platform check-browser check-required-fixes check-cli check-contracts release readiness
help:
	@echo "Run make check for every gate, or check-platform, check-browser, check-required-fixes, check-cli or check-contracts for one component."
	@echo "Run make release to run every gate, then build the committed tree into an image."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
check: check-platform check-browser check-required-fixes check-cli check-contracts
# A fresh clone needs nothing first: the libraries, the page packages and the shared
# library copies the type check reads are all fetched or built here.
check-platform:
	cd platform && mix deps.get && npm ci --prefix assets && mix do regent_ui.assets + regent_blog.assets + regent_identity.assets + regent_agent_access.assets && mix precommit
# The browser walk (platform/assets/test/browser): pages at 320, 390 and 1280 in
# headless Chromium. It starts its own server on its own database, patchbay_dev_browser.
check-browser:
	cd platform/assets && npx playwright test
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
REGENTS_CLI_REV := 6dacddd52797115125738177a3a0dee914724ab1
check-cli:
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json platform/priv/public/openapi.json
check-contracts:
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
