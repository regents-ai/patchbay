#!/bin/sh
# The browser walk's server, from its database to its end (playwright.config.ts).
# It makes the run's own database, signs the walk's people in, builds the pages and
# serves them. When the server fails to start or stops by itself, it drops the
# database on its way out; when Playwright stops it, teardown.ts drops it.
set -eu
cd "$(dirname "$0")/../../../.."

drop() { mix run --no-start assets/test/browser/support/drop.exs; }
trap drop EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# The outside services' settings are cleared, and PATCHBAY_WALK points the rest at
# nothing on this machine (config/dev.exs).
unset BASE_RPC_URL PATCHBAY_ETHEREUM_NODE_URL ETHEREUM_READ_RPC_URL PATCHBAY_SIWA_URL \
  SIWA_HOSTED_URL SIWA_HOSTED_SIGNING_KEY SIWA_ACTIVITY_READ_TOKEN OPENROUTER_API_KEY \
  PATCHBAY_INDEXNOW_KEY
export PATCHBAY_WALK=true POOL_SIZE=3 PRIVY_APP_ID=browser-walk-app
PRIVY_VERIFICATION_KEY="$(openssl ecparam -name prime256v1 -genkey 2>/dev/null | openssl ec -pubout 2>/dev/null)"
export PRIVY_VERIFICATION_KEY

mkdir -p tmp
rm -f "tmp/walk-outside${PATCHBAY_DEV_PARTITION}.txt"
mix ecto.setup > /dev/null
mix run assets/test/browser/support/sign_in.exs
mix assets.build > /dev/null
mix phx.server
