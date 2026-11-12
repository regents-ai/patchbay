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
# labelled with the short commit; the switch to it then runs /app/bin/migrate
# before the new machine takes traffic (platform/docs/DEPLOY.md). An earlier
# image goes back with `fly deploy --app patchbay-regents --image <previous
# image>`, run under a database place as DEPLOY.md shows.
#
# Never wrap this script in `lockf`: it takes its own locks.
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

app=patchbay-regents
image="registry.fly.io/$app:${commit:0:7}"

# The switch to the new image runs the migrations and briefly adds a second
# machine's connections to the production database every site shares, which
# fits two switches at once. It takes whichever of the two places is free, or
# waits for the second.
switch() {
  local place=/tmp/regent-shared-db-release.lock
  lockf -k -s -t 0 "$place" true || place=/tmp/regent-shared-db-release-2.lock
  echo "==> Deploying $image (waits for $place if it is taken)"
  lockf -k "$place" fly deploy --config fly.toml --app "$app" --image "$image" --ha=false
}

# The build touches no database, so it takes no shared place.
release() {
  cd "$context"
  echo "==> Building $image from commit $commit"
  fly deploy --config fly.toml --app "$app" --build-only --push --remote-only --no-cache \
    --build-arg SOURCE_COMMIT="$commit" \
    --image-label "${commit:0:7}"
  switch
}

# One Patchbay deploy at a time; other sites' deploys never wait on it.
lock="/tmp/regent-release-$app.lock"
echo "==> Waiting for any other Patchbay deploy holding $lock"
export app commit image context
export -f release switch
lockf -k "$lock" bash -euo pipefail -c release
