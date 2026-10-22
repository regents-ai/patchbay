# Base images are pinned by digest; each comment names the tag it was taken from.
# They match ash-template's platform/Dockerfile.

# hexpm/elixir:1.20.4-erlang-29.1.2-debian-bookworm-20261020-slim
ARG BUILDER_IMAGE="docker.io/hexpm/elixir@sha256:11ab449084960993491cdc3493be292464c5a63e8f753ed2afe351486471b69a"
# debian:bookworm-20261020-slim
ARG RUNNER_IMAGE="docker.io/library/debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8"

# The asset build installs the Privy bridge's npm packages, so the builder needs
# a Node of its own; the release image below never sees it.
# node:26.12.0-bookworm-slim
FROM docker.io/library/node@sha256:298992629d69bbd5b2b03ad57094d8e4fcb3a8eeb7c4e25d29de656519568913 AS node

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git curl python3 \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

# prepare build dir
WORKDIR /app/platform

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies; the shared Regent libraries come from GitHub at the
# commits mix.exs pins
COPY platform/mix.exs platform/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY platform/config/config.exs platform/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY platform/priv priv
COPY platform/lib lib
COPY CHANGELOG.md /app/CHANGELOG.md
COPY blog /app/blog
COPY skills /app/skills
COPY platform/assets assets

# The escrow module compiles the contract's ABI straight into itself, so the
# ABI has to be in the image before anything is compiled.
COPY contracts/abi ../contracts/abi

# The asset build reads colocated hooks out of the build directory, so the
# application is compiled first.
RUN mix compile

# download the esbuild binary, then build and digest the assets
RUN mix assets.setup
RUN mix assets.deploy

# changes to config/runtime.exs don't require recompiling the code
COPY platform/config/runtime.exs config/

COPY platform/rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

# Outbound TLS needs no CA bundle from the image: the release trusts castore's
# list (Patchbay.Application).
RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/platform/_build/${MIX_ENV}/rel/patchbay ./

# The commit this image is built from, reported by /webmcp/health. Build with
# --build-arg SOURCE_COMMIT=<full commit>; a release without it does not start.
ARG SOURCE_COMMIT
ENV SOURCE_COMMIT="${SOURCE_COMMIT}"

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
