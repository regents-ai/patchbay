#!/usr/bin/env bash

set -euo pipefail

test_file="test/patchbay_web/live/webmcp/room_live_test.exs"

for iteration in $(seq 1 10); do
  echo "deterministic Patchbay proof: iteration ${iteration}/10"
  env -u OPENAI_API_KEY \
    PATCHBAY_DEMO_FALLBACK=true \
    MIX_TEST_PARTITION="patchbay_zde5_e2e_${iteration}" \
    mix test "${test_file}"
done
