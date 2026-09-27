.DEFAULT_GOAL := help
.PHONY: help check check-platform check-required-fixes check-contracts
help:
	@echo "Run make check for every gate, or check-platform, check-required-fixes or check-contracts for one component."
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
