#!/usr/bin/env bash

set -euo pipefail

test_file="test/patchbay_web/live/webmcp/room_live_test.exs"

# Each checkout gets its own test partitions, so two of them can run this proof
# at the same time without sharing a database. The default comes from the
# checkout's own directory name; PATCHBAY_E2E_PARTITION_PREFIX overrides it.
checkout_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_prefix="$(printf '%s' "${checkout_dir##*/}" | tr -c 'a-zA-Z0-9' '_' | tr 'A-Z' 'a-z')"
partition_prefix="${PATCHBAY_E2E_PARTITION_PREFIX:-${default_prefix}}"

for iteration in $(seq 1 10); do
  echo "deterministic Patchbay proof: iteration ${iteration}/10 (partition ${partition_prefix}_e2e_${iteration})"
  npm test --prefix assets
  env -u OPENAI_API_KEY \
    PATCHBAY_DEMO_FALLBACK=true \
    MIX_TEST_PARTITION="${partition_prefix}_e2e_${iteration}" \
    mix test "${test_file}"
done
