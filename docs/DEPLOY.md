# Deploying the public Patchbay room

Patchbay ships as a standard Phoenix release in a Docker image and runs on one
Fly.io machine behind HTTPS. The commands below are the whole deployment; run
them in order from the repository root.

Before starting: install `flyctl`, run `fly auth login`, and note the Fly
organisation the app should live in (`fly orgs list`).

The examples use the app name `patchbay-regents`, which is also the `app` value
in `fly.toml`. To use a different name, change it in `fly.toml`, use it in every
command below, and set `PHX_HOST` to the matching hostname.

## No volume is required

All durable state lives in Postgres: rooms, tool revisions, invocations,
verifications, repair proposals and the timeline. Skill text entered in the page
is stored as a database column, and nothing a visitor submits is ever written to
the machine's disk. A machine can be replaced at any time without data loss, so
no Fly volume is created or attached.

## 1. Create the app

```sh
fly apps create patchbay-regents --org personal
```

Replace `personal` with the organisation from `fly orgs list`.

## 2. Create and attach Postgres

This sheet targets an unmanaged Postgres cluster created with `fly postgres
create`. The app reaches it only over the organisation's private IPv6 network,
which is why `ECTO_IPV6` is set in `fly.toml` and no TLS is configured for the
database connection. Fly's separate Managed Postgres product is a different
service with a different connection string: it expects a TLS connection, so it
needs `ssl: true` added to the repository configuration in
`config/runtime.exs`, and `ECTO_IPV6` revisited to match the address it hands
out. Do not mix the two.

```sh
fly postgres create \
  --name patchbay-regents-db \
  --org personal \
  --region ewr \
  --initial-cluster-size 1 \
  --vm-size shared-cpu-1x \
  --volume-size 1
```

```sh
fly postgres attach patchbay-regents-db --app patchbay-regents
```

`attach` creates the database and role and sets the `DATABASE_URL` secret on the
app. Do not set `DATABASE_URL` by hand.

## 3. Set the remaining secrets

```sh
fly secrets set --app patchbay-regents \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  PHX_HOST="patchbay-regents.fly.dev"
```

`SECRET_KEY_BASE` and `PHX_HOST` are required; the release refuses to boot
without them. `PHX_HOST` must be the exact public hostname, because the
LiveView socket rejects connections from any other origin.

Live inference is optional. Set the key only if the demo should call OpenAI:

```sh
fly secrets set --app patchbay-regents OPENAI_API_KEY="sk-..."
```

For a deterministic public walkthrough with no model calls, leave
`OPENAI_API_KEY` unset and enable the checked-in fallback instead. The page
labels fallback provenance:

```sh
fly secrets set --app patchbay-regents PATCHBAY_DEMO_FALLBACK=true
```

Turn it off again with `fly secrets unset --app patchbay-regents
PATCHBAY_DEMO_FALLBACK`. Never set both a real key and the fallback if the
demo is meant to show live inference.

Check what is set at any time with `fly secrets list --app patchbay-regents`;
values are never displayed.

## 4. Deploy

```sh
fly deploy --app patchbay-regents --remote-only --ha=false
```

`--ha=false` is required: without it Fly creates a second machine for high
availability, and this demo is deliberately one shared-cpu-1x 512MB machine.

The image is built from `Dockerfile`. Before the new machine takes traffic, Fly
runs the release command `/app/bin/migrate`, which applies every pending
migration. A failed migration fails the deploy and leaves the previous release
serving.

With a single machine, a deploy replaces it rather than draining traffic onto a
second one, so expect a gap of a few seconds during which the URL is
unreachable and open rooms reconnect. Do not deploy while a demo is being
watched.

## 5. Verify

```sh
curl -s https://patchbay-regents.fly.dev/webmcp/health | python3 -m json.tool
```

Expected:

```json
{
    "status": "ok",
    "version": "0.1.0",
    "database": "ok",
    "migrations": "current",
    "demo_fallback_enabled": true,
    "live_inference_configured": false
}
```

That body is the deterministic mode: the checked-in fallback is on and no key
is present. In live-inference mode the last two fields are the other way round:

```json
    "demo_fallback_enabled": false,
    "live_inference_configured": true
```

Both `true` means a key is present but the fallback would still be used when a
call fails, which is usually not what a public demo should be showing.

The endpoint answers `503` whenever the database is unreachable or a migration
is still pending, which is also what the platform health check in `fly.toml`
polls, so a bad release is taken out of rotation instead of serving errors. The
API key itself is never included in the response.

Then open the room. The bare domain redirects to it, so either URL works:

```sh
fly open --app patchbay-regents
```

The seeded room and its `v1` revision are created on the first visit to
`/webmcp/rooms/skill-uplift`, so there is no seeding command to run after a
deploy. The **Reset demo** control in the page returns the room to generation 1
between walkthroughs.

Useful follow-ups:

```sh
fly status --app patchbay-regents
fly logs --app patchbay-regents
```

## 6. Enabling the WebMCP origin trial later

A public origin needs an origin-trial token before Chrome exposes
`document.modelContext`; the local `chrome://flags` path used in
[LOCAL_WEBMCP.md](LOCAL_WEBMCP.md) does not apply to visitors. Register the
exact origin (`https://patchbay-regents.fly.dev`) on Chrome's origin trials
site, then deliver the token one of two ways:

- **Response header** (preferred, covers every page): add
  `Origin-Trial: <token>` in `PatchbayWeb.Plugs.BrowserPolicy`, reading the
  token from an environment variable and setting it with
  `fly secrets set --app patchbay-regents WEBMCP_ORIGIN_TRIAL_TOKEN=...`.
- **Meta tag** (one page): add
  `<meta http-equiv="origin-trial" content={@origin_trial_token} />` to the
  `<head>` in `lib/patchbay_web/components/layouts/root.html.heex`.

The token is origin-specific and expires, so it belongs in a secret, never in
this repository. Do not send `Origin-Agent-Cluster: ?0`; WebMCP is only exposed
in origin-isolated documents.

## 7. Rollback

List the releases and note the version you want to return to:

```sh
fly releases --app patchbay-regents --image
```

Redeploy that image:

```sh
fly deploy --app patchbay-regents --image registry.fly.io/patchbay-regents:deployment-<id>
```

A rollback replays no migrations. If the bad release migrated the database,
redeploy the previous image first, then roll the schema back with the
migration version from `priv/repo/migrations`. Keep that order: a running
machine caches its migration status for its lifetime, so rolling the schema
back under the newer image would leave it reporting healthy while its code is
ahead of the database:

```sh
fly ssh console --app patchbay-regents \
  -C "/app/bin/patchbay eval 'Patchbay.Release.rollback(Patchbay.Repo, 20260901132657)'"
```
