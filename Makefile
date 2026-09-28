.DEFAULT_GOAL := help
.PHONY: help check check-platform check-required-fixes check-contracts release
help:
	@echo "Run make check for every gate, or check-platform, check-required-fixes or check-contracts for one component."
	@echo "Run make release to run every gate, then build the committed tree into an image and start it against a throwaway database."
check: check-platform check-required-fixes check-contracts
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
check-contracts:
	cd contracts && forge fmt --check && forge build --offline && forge test --offline
# The release checks and builds exactly the committed tree, so every change must
# be committed first. A failing gate stops it before anything is built.
release:
	@test -z "$$(git status --porcelain)" || { echo "Commit every change first: the release checks and builds the committed tree." >&2; exit 1; }
	$(MAKE) check
	scripts/release.sh
