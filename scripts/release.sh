#!/usr/bin/env bash
# Builds the committed tree into the release image.
# Run it through `make release`, which runs every gate on that same tree first.
#
# The build context is `git archive` of HEAD, so nothing uncommitted, ignored or
# outside this repository enters the image. The whole repository goes in because
# the Dockerfile also copies the changelog, the blog, the skills and the
# contract's ABI from beside platform/. The build reuses no cached layers, and
# the Dockerfile fetches every dependency at the version the lockfiles pin; the
# shared libraries' repositories are public, so the build takes no credentials.
#
# Patchbay runs against production only, so the image is not started here.
# Sentinel alerts when a deployed release fails; it does not roll one back.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

commit="$(git rev-parse HEAD)"
image="patchbay:${commit:0:12}"

echo "==> Building $image from commit $commit"
git archive --format=tar "$commit" |
  docker build --no-cache --file platform/Dockerfile \
    --build-arg SOURCE_COMMIT="$commit" \
    --label "org.opencontainers.image.revision=$commit" --tag "$image" -
digest="$(docker image inspect --format '{{.Id}}' "$image")"

echo
echo "Release built"
echo "  app commit      $commit"
git show "$commit:platform/mix.lock" | grep -oE '\{:git, "[^"]+", "[0-9a-f]{40}"' | sort -u |
  sed -E 's/\{:git, "([^"]+)", "([0-9a-f]+)"/  shared library  \1 \2/'
echo "  image           $image"
echo "  image digest    $digest"
