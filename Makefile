.DEFAULT_GOAL := help
.PHONY: help check-platform check-contracts
help:
	@echo "Run check-platform or check-contracts for the changed component."
check-platform:
	cd platform && mix precommit
check-contracts:
	cd contracts && forge fmt --check && forge build --offline && forge test --offline
