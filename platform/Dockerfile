# Base images are pinned by digest; each comment names the tag it was taken from.
# They match ash-template's platform/Dockerfile.

# gcc:16.2.0-trixie
FROM docker.io/library/gcc@sha256:07280eb2e744f1b7a2d8d4a3894c089ea07266c109758afc388a634bd098e4eb AS native
# hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261027-slim
FROM docker.io/hexpm/elixir@sha256:bb266918bb26de22fb02ff19430f47e76331001601df0fc820806c21cd4164e0 AS elixir
# node:26.13.0-trixie-slim
FROM docker.io/library/node@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39 AS node
# debian:trixie-20261027-slim
FROM docker.io/library/debian@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS slim

# The build context is the repository root: the app is in platform/.
# The asset build installs the Privy bridge's npm packages, so it needs a Node
# of its own; the release image below never sees it.
FROM native AS assets

ENV npm_config_nodedir=/usr/local
WORKDIR /app
COPY --from=node /usr/local /usr/local
COPY platform/assets/package.json platform/assets/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

FROM native AS build

ENV MIX_ENV=prod
ENV HOME=/root
WORKDIR /app/platform

COPY --from=elixir /usr/local /usr/local
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

# Hex and rebar3 at fixed versions; rebar3 is the build Mix itself would pick
# for this Elixir and OTP, checked against its published SHA-512.
RUN mix local.hex 2.6.0 --force && \
  mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.28.0-otp-29 \
    --sha512 b51946058fbe4aa823185bfe27204be59be439982ac3a3e1dbd9f8260b9af046fcfdfbd9066283c3fbba5a2a45dc3570550c12a9a548daf223b80cac222a6d0f \
    --force

# Shared Regent libraries arrive here from GitHub at the commits mix.lock pins;
# a mix.lock that no longer matches mix.exs stops the build.
COPY platform/mix.exs platform/mix.lock ./
COPY platform/config config
RUN mix deps.get --only prod --check-locked && mix deps.compile

COPY platform/lib lib
COPY platform/priv priv
COPY platform/rel rel
COPY platform/assets assets
COPY CHANGELOG.md /app/CHANGELOG.md
COPY blog /app/blog
COPY skills /app/skills
COPY cli/commands.json /app/cli/commands.json
COPY --from=assets /app/node_modules assets/node_modules

# The escrow module compiles the contract's ABI straight into itself, so the
# ABI has to be in the image before anything is compiled.
COPY contracts/abi ../contracts/abi

# The asset build reads colocated hooks out of the build directory, so the
# application is compiled first.
RUN mix compile && mix assets.deploy && mix release

# The release carries its own ERTS, so the runtime image needs no Elixir and no
# Erlang install. It does still need the OpenSSL library the crypto NIF links
# against, which the slim base lacks. It is lifted from the builder image, which
# is only sound while the two images are the same Debian release, so this stage
# asserts that first and the build stops here if a base ever moves. Lifting to a
# fixed path also keeps the runtime stage from naming a library directory that
# differs per architecture. Outbound TLS needs no CA bundle from the image: the
# release trusts castore's list (`Patchbay.Application`).
FROM elixir AS runtime-support

COPY --from=slim /etc/os-release /slim-os-release
RUN set -eu; \
  builder="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"; \
  runtime="$(. /slim-os-release; printf '%s' "$VERSION_CODENAME")"; \
  if [ "$builder" != "$runtime" ]; then \
    echo "runtime base is Debian $runtime but the builder is Debian $builder;" \
      "the OpenSSL library may not be lifted across releases" >&2; \
    exit 1; \
  fi; \
  mkdir /runtime-support; \
  cp /usr/lib/*-linux-gnu/libcrypto.so.3 /runtime-support/

FROM slim AS app

# The builder image sets this and the slim base does not. Without it the VM
# runs with latin1 name encoding, which Elixir warns about at boot.
ENV LANG=C.UTF-8
ENV HOME=/app
WORKDIR /app

# OTP opens libsctp when it starts and prints a warning on every boot, migration
# and `bin/patchbay rpc` without it.
RUN apt-get update \
  && apt-get install -y --no-install-recommends coreutils libsctp1 \
  && rm -f /var/lib/apt/lists/*_*

COPY --from=runtime-support /runtime-support/libcrypto.so.3 /usr/lib/

RUN groupadd --system --gid 1001 app \
  && useradd --system --uid 1001 --gid app --home-dir /app app

COPY --from=build --chown=app:app /app/platform/_build/prod/rel/patchbay ./

# The commit this image is built from, which /capabilities.json names.
# scripts/deploy.sh passes it; a build without it stops here.
ARG SOURCE_COMMIT
RUN test -n "$SOURCE_COMMIT"
ENV SOURCE_COMMIT=$SOURCE_COMMIT

USER app

EXPOSE 4000

CMD ["/app/bin/server"]
