.DEFAULT_GOAL := help
.PHONY: help check check-platform check-required-fixes check-cli check-contracts release
help:
	@echo "Run make check for every gate, or check-platform, check-required-fixes, check-cli or check-contracts for one component."
	@echo "Run make release to run every gate, then build the committed tree into an image and start it against a throwaway database."
check: check-platform check-required-fixes check-cli check-contracts
check-platform:
	cd platform && mix precommit
# Every site runs the same check against ash-template's current main branch, so a
# newly published required fix reaches every site's next gate. Needs `gh auth login`.
TEMPLATE := repos/regents-ai/ash-template
check-required-fixes:
	cd platform && mkdir -p _build && rev=$$(gh api $(TEMPLATE)/commits/main --jq .sha) \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/platform/scripts/check_required_fixes.exs?ref=$$rev" > _build/check_required_fixes.exs \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/security/required-fixes.json?ref=$$rev" > _build/required-fixes.json \
	&& elixir _build/check_required_fixes.exs "ash-template $$rev" < _build/required-fixes.json
# The command description check is regents-cli's own checker at the commit pinned
# here, fetched from GitHub with the schema it reads and the two packages at the
# versions that commit declares. Move the pin in a commit. Needs `gh auth login`.
REGENTS_CLI := repos/regents-ai/regents-cli
REGENTS_CLI_REV := 25e1868fea8efd7b504f1ff7015826e2074ff8bb
CLI_CHECKER := platform/_build/regents-cli-$(REGENTS_CLI_REV)
check-cli:
	mkdir -p $(CLI_CHECKER)/scripts $(CLI_CHECKER)/schemas \
	&& for file in scripts/check-platform-commands.mjs scripts/dependency-preflight.mjs schemas/commands.v1.json; do \
	  gh api -H "Accept: application/vnd.github.raw" "$(REGENTS_CLI)/contents/$$file?ref=$(REGENTS_CLI_REV)" > $(CLI_CHECKER)/$$file || exit 1; \
	done \
	&& packages=$$(gh api -H "Accept: application/vnd.github.raw" "$(REGENTS_CLI)/contents/package.json?ref=$(REGENTS_CLI_REV)" \
	  | node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")).devDependencies; console.log(`ajv@$${d.ajv} yaml@$${d.yaml}`)') \
	&& npm install --prefix $(CLI_CHECKER) --no-save --no-package-lock --no-audit --no-fund --silent $$packages \
	&& node $(CLI_CHECKER)/scripts/check-platform-commands.mjs cli/commands.json platform/priv/static/openapi.json platform/priv/static/agent-payments.openapi.json
check-contracts:
	cd contracts && forge fmt --check && forge build --offline && forge test --offline
# The release checks and builds exactly the committed tree, so every change must
# be committed first. A failing gate stops it before anything is built.
release:
	@test -z "$$(git status --porcelain)" || { echo "Commit every change first: the release checks and builds the committed tree." >&2; exit 1; }
	$(MAKE) check
	scripts/release.sh
