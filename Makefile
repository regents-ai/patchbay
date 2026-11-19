.DEFAULT_GOAL := help
.PHONY: help check platform-deps check-platform platform-assets platform-precommit check-required-fixes check-cli check-siwa-latest check-contracts release readiness
help:
	@echo "Run make check for every gate, side by side, each writing its output to platform/_build/check/<gate>.log; it prints every gate's log, the failed ones last, then one line per gate. Or run check-platform, check-required-fixes, check-cli, check-siwa-latest or check-contracts for one component."
	@echo "Run make release to run every gate, then build the committed tree into an image."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
# make check fetches the libraries first (platform-deps), since two gates read them,
# then runs its gates side by side, each writing its output to $(CHECK_LOGS)/<gate>.log,
# then prints every gate's log, the failed ones last, and one line per gate, and fails
# when any gate failed. The gates of the quoted lane run in turn: platform-assets
# installs assets/node_modules afresh and copies the shared libraries' files into
# assets/vendor, which mix precommit's type check reads. The other gates write nothing
# another reads.
CHECK_LANES := "platform-assets platform-precommit" check-required-fixes check-cli check-siwa-latest check-contracts
CHECK_GATES := $(subst ",,$(CHECK_LANES))
CHECK_LOGS := platform/_build/check
# Each gate's budget in seconds, about 40% over its usual time in make check on a
# 16-core Mac (Nov 2026), and 5 s for a gate that takes a second or two. A gate over
# its budget gets a SLOW line under its own at the end; it never fails the check.
CHECK_BUDGETS := platform-assets:50 platform-precommit:15 check-required-fixes:5 check-cli:5 \
  check-siwa-latest:5 check-contracts:65
check: platform-deps
	@mkdir -p $(CHECK_LOGS) && : > $(CHECK_LOGS)/results
	@echo "Running $(words $(CHECK_GATES)) gates side by side; each writes $(CHECK_LOGS)/<gate>.log."
	@for lane in $(CHECK_LANES); do \
	  for gate in $$lane; do \
	    start=$$(date +%s); \
	    $(MAKE) --no-print-directory $$gate > $(CHECK_LOGS)/$$gate.log 2>&1; \
	    code=$$?; echo "$$gate $$code $$(( $$(date +%s) - start ))" >> $(CHECK_LOGS)/results; \
	  done & \
	done; wait
	@failed=; \
	for gate in $(CHECK_GATES); do \
	  if grep -q "^$$gate 0 " $(CHECK_LOGS)/results; then \
	    echo; echo "== $$gate ($(CHECK_LOGS)/$$gate.log)"; cat $(CHECK_LOGS)/$$gate.log; \
	  else failed="$$failed $$gate"; fi; \
	done; \
	for gate in $$failed; do \
	  echo; echo "== $$gate FAILED ($(CHECK_LOGS)/$$gate.log)"; cat $(CHECK_LOGS)/$$gate.log; \
	done; \
	echo; \
	for gate in $(CHECK_GATES); do \
	  set -- $$(grep "^$$gate " $(CHECK_LOGS)/results); \
	  if [ "$$2" = 0 ]; then echo "$$gate: ok in $$3 s"; else echo "$$gate: FAILED after $$3 s"; fi; \
	  budget=$$(printf '%s\n' $(CHECK_BUDGETS) | sed -n "s/^$$gate://p"); \
	  if [ "$$3" -gt "$$budget" ]; then echo "SLOW: $$gate took $$3 s (budget $$budget s)"; fi; \
	done; \
	test -z "$$failed"
# A new checkout needs nothing first: the libraries (platform-deps), the page packages,
# esbuild and the shared library copies the type check reads (platform-assets) are all
# fetched or built here.
check-platform: platform-deps platform-assets platform-precommit
platform-deps:
	cd platform && mix deps.get
platform-assets:
	cd platform && mix assets.setup && mix do regent_ui.assets + regent_blog.assets + regent_identity.assets + regent_agent_access.assets
platform-precommit:
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
# here, run by uv straight from GitHub. Move the pin in a commit.
REGENTS_CLI_REV := c12d8563c46e8b5229e32db76c1a104fb469b7b7
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
