#!/bin/sh
# Runs the tests tagged :committed, whose transactions must really commit (two
# saves racing in separate transactions), in a test database of their own,
# then drops that database, so nothing they write is removed row by row and
# nothing they leave reaches the main run's database.
set -u
cd "$(dirname "$0")/.."
export MIX_ENV=test
export MIX_TEST_PARTITION="committed${MIX_TEST_PARTITION:-}"
mix test --only committed --warnings-as-errors
status=$?
mix ecto.drop --quiet
exit $status
