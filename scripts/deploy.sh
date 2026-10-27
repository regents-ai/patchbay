#!/usr/bin/env bash
# Deploys the committed tree to patchbay.help, and nothing else.
#
#   scripts/deploy.sh
#
# It refuses a working tree with any change, and a commit that is not on
# origin/main, so what runs is always what the repository holds: push the commit
# to main first. The build context is `git archive` of this commit with
# platform/fly.toml beside it, as the Dockerfile copies from the whole
# repository. Fly's remote builder builds the image without cached layers,
# labelled with the short commit, and runs /app/bin/migrate before the new
# machine takes traffic (platform/docs/DEPLOY.md). An earlier image goes back
# with `fly deploy --app patchbay-regents --image <previous image>`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy: commit or remove every change first." >&2
  exit 1
fi

git fetch --quiet origin main
commit="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "$commit" origin/main; then
  echo "Refusing to deploy: ${commit:0:7} is not on origin/main. Push it to main first." >&2
  exit 1
fi

context="$(mktemp -d)"
trap 'rm -rf -- "$context"' EXIT

echo "==> Assembling the build context from commit ${commit:0:7}"
git archive --format=tar "$commit" | tar -x -C "$context"
cp "$context/platform/fly.toml" "$context/fly.toml"

# Every site shares one production database, and a release briefly doubles a
# site's connections, so releases from this machine take turns: the build and
# release run under one lock that every site's deploy takes, and wait for it.
lock=/tmp/regent-shared-db-release.lock
echo "==> Deploying ${commit:0:7} to patchbay-regents (waits for any other release holding $lock)"
cd "$context"
lockf -k "$lock" fly deploy --config fly.toml --app patchbay-regents --remote-only --ha=false --no-cache \
  --build-arg SOURCE_COMMIT="$commit" \
  --image-label "${commit:0:7}"
