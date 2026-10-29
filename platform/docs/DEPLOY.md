# Deploying Patchbay

Patchbay ships as a standard Phoenix release in a Docker image and runs on one
Fly.io machine behind HTTPS. The commands below are the whole deployment; run
them in order from the repository root.

Before starting: install `flyctl`, run `fly auth login`, and note the Fly
organisation the app should live in (`fly orgs list`).

This sheet stands the site up. Turning on sign-in, payments and the escrow
contract is a separate ordered sequence: see [GO_LIVE.md](GO_LIVE.md).

The examples use the app name `patchbay-regents`, which is also the `app` value
in `fly.toml`. To use a different name, change it in `fly.toml`, use it in every
command below, and set `PHX_HOST` to the matching hostname.

## No volume is required

All durable state lives in Postgres, and nothing a visitor submits is ever
written to the machine's disk. A machine can be replaced at any time without data loss, so
no Fly volume is created or attached.

## 1. Create the app

```sh
fly apps create patchbay-regents --org regent
```

Replace `personal` with the organisation from `fly orgs list`.

## 2. Connect to the shared database

Patchbay keeps its data in the shared Regent PostgreSQL cluster
(`regents-platform-prod`, id `dzx6qo6xqzvojpv5`), in its own schema, beside
every other Regent site. `Patchbay.DatabaseConfig` admits only the cluster's
direct host, `direct.dzx6qo6xqzvojpv5.flympg.net`, over verified TLS, on port
5432 and with no query options. Two secrets name it:

- `DATABASE_POOLED_URL`: the serving connection, five connections named
  `patchbay-web`.
- `DATABASE_DIRECT_URL`: release commands (`/app/bin/migrate`), with the
  migration owner's login.

`fly.toml` sets the role and the cluster (`PATCHBAY_DEPLOYMENT_ROLE`,
`PATCHBAY_DATABASE_TARGET_MODE`, `PATCHBAY_DATABASE_CLUSTER_ID`,
`PATCHBAY_DATABASE_CLUSTER_NAME`); none of them is secret. A boot that finds
any of these missing or different stops before connecting. It also sets
`PATCHBAY_SHOWCASE`, `public` or `off`: whether the motion lab at `/animations`
exists. A boot without it stops.

## 3. Set the remaining secrets

```sh
fly secrets set --app patchbay-regents \
  SECRET_KEY_BASE="$(cd platform && mix phx.gen.secret)" \
  PHX_HOST="patchbay-regents.fly.dev"
```

`SECRET_KEY_BASE` and `PHX_HOST` are required; the release refuses to boot
without them. `PHX_HOST` must be the exact public hostname, because the
LiveView socket rejects connections from any other origin.

`OPENAI_API_KEY` is used only for the weekly ChatGPT questions
(`Patchbay.AnswerWatch`):

```sh
fly secrets set --app patchbay-regents OPENAI_API_KEY="sk-..."
```

Error reports go to Sentry once `SENTRY_DSN` is set; `SENTRY_ENVIRONMENT` and
`SENTRY_RELEASE` label them. Unset, errors are only logged.

Check what is set at any time with `fly secrets list --app patchbay-regents`;
values are never displayed.

### Spend limits

A free fix from the home page needs no sign-in, so anyone can start model
calls, and every call is billed to the deployment's own keys. Two limits bound
that, and both have working defaults that need no configuration:

| Variable | Default | What it does |
| --- | --- | --- |
| `PATCHBAY_DAILY_MODEL_CALLS` | `2000` | Model calls the whole deployment may make in any rolling 24 hours |
| `PATCHBAY_DAILY_FREE_FIXES` | `200` | Free fixes the home page gives in that window, across every visitor |

Lower them to keep spending down:

```sh
fly secrets set --app patchbay-regents \
  PATCHBAY_DAILY_MODEL_CALLS=100 \
  PATCHBAY_DAILY_FREE_FIXES=10
```

A value that is not a whole number is ignored and the default stands, so read
the value back with `fly secrets list` after changing one.

These limits protect the site from a burst of traffic; they are not a billing
guarantee. Also set a hard monthly spend limit on the accounts behind
`OPENROUTER_API_KEY` and `OPENAI_API_KEY`, so a mistake anywhere in this stack
cannot run up an unbounded bill.

## 4. Deploy

Push the commit to `main` first, then from a clean checkout of it:

```sh
scripts/deploy.sh
```

Every Regent site shares one production database, and a release briefly doubles
a site's connections, so releases take turns. Before deploying, read the newest
release of each other app on it (`fly releases --app <app> --json` for
autolaunch-sh, keyfleet, keyfleet-code, regents-sh-web, techtree-sh,
template-regents-sh and sentinel-regent) and wait while any shows
`"InProgress": true`. The script then builds and releases under
`lockf -k /tmp/regent-shared-db-release.lock`, which every site's deploy on the
same Mac takes and waits for, since Fly lists a release only after its build.
Run anything done by hand that builds, releases or restarts `patchbay-regents`
or `patchbay-shots`, such as `fly secrets set` or an image redeploy, under the
same lock: `lockf -k /tmp/regent-shared-db-release.lock fly ...`.

It refuses a checkout with any change and a commit that `origin/main` does not
contain. It builds `git archive` of the commit, so `SOURCE_COMMIT` is always
the full commit the image is built from; `/capabilities.json` names it as
`build.commit`, beside the Fly image the machine runs as `build.release`. An
image built without it stops at the Dockerfile's check, so nothing is
released.

`--ha=false` is required: without it Fly creates a second machine for high
availability, and this site is deliberately one shared-cpu-1x 512MB machine.

The image is built from `platform/Dockerfile` with the monorepo root as its context. Before the new machine takes traffic, Fly
runs the release command `/app/bin/migrate`, which applies every pending
migration. A failed migration fails the deploy and leaves the previous release
serving.

Deploys are blue-green (`strategy = "bluegreen"` in `platform/fly.toml`): Fly
starts a new machine beside the running one and moves traffic to it only once
it answers `/healthz` with `ok`, which needs its database to answer. A new
release that never answers is removed and
the previous one keeps serving. Open pages reconnect when traffic moves.

## 5. Verify

```sh
curl -s https://patchbay-regents.fly.dev/capabilities.json | python3 -m json.tool
```

Its `build.commit` must be the full commit you deployed, and `build.release` the
image Fly runs. Then:

```sh
curl -s https://patchbay-regents.fly.dev/webmcp/health | python3 -m json.tool
```

Expected:

```json
{
    "status": "ok",
    "database": "ok",
    "migrations": "current"
}
```

The endpoint answers `503` whenever the database is unreachable or a migration
is still pending, which is also what the platform health check in `fly.toml`
polls, so a bad release is taken out of rotation instead of serving errors.

## 5. Custom domain (patchbay.help)

The app serves whichever hostname `PHX_HOST` names, so the domain change is
two steps. First tell Fly about the hostname and read back the records it
wants:

```sh
fly certs add patchbay.help --app patchbay-regents
fly certs show patchbay.help --app patchbay-regents
```

Create those records where the domain's DNS is managed (for a domain held at
Vercel, in the Vercel Domains DNS panel): the `A` and `AAAA` records pointing
at the app's IPv4 and IPv6 addresses from `fly ips list --app patchbay-regents`,
plus the `_acme-challenge` CNAME that `fly certs show` prints. Fly issues the
certificate once the records resolve; `fly certs check patchbay.help` reports
progress.

Then switch the app to the new hostname and let it restart:

```sh
fly secrets set --app patchbay-regents PHX_HOST="patchbay.help"
```

Until `PHX_HOST` changes, the page loads on the new domain but its live
connection is refused, so do both steps together. The `fly.dev` hostname keeps
working afterwards only if `PHX_HOST` still names it, so give the final domain
out only after this step is verified with `curl -sI https://patchbay.help/`
returning a `200`.

Then open the site:

```sh
fly open --app patchbay-regents
```

Useful follow-ups:

```sh
fly status --app patchbay-regents
fly logs --app patchbay-regents
```

## 6. The WebMCP origin trial

A public origin needs Chrome's WebMCP origin-trial token before Chrome offers
`document.modelContext` to visitors; the local `chrome://flags` path in
[LOCAL_WEBMCP.md](LOCAL_WEBMCP.md) does not apply to them. Patchbay's token is
registered for `https://patchbay.help` and expires on 17 November 2026.

The token is public, so it is kept in the source:
`PatchbayWeb.Plugs.BrowserPolicy` (`lib/patchbay_web/plugs/browser_policy.ex`)
sends it as an `Origin-Trial` response header on every page, beside
`Permissions-Policy: tools=(self)`. To renew it, register the same origin again
on Chrome's origin trials site, replace the token in that file, update the
expiry in the comment beside it, and release. No Fly secret is involved.

Do not send `Origin-Agent-Cluster: ?0`; WebMCP is only exposed in
origin-isolated documents.

## 7. Rollback

List the releases and note the version you want to return to:

```sh
fly releases --app patchbay-regents --image
```

Redeploy that image:

```sh
lockf -k /tmp/regent-shared-db-release.lock fly deploy --config platform/fly.toml --app patchbay-regents --image registry.fly.io/patchbay-regents:deployment-<id>
```

A rollback replays no migrations. When the bad release only added tables or
columns that are empty or have a default, the previous image runs on the newer
schema as it is, and redeploying it is the whole rollback.

Otherwise redeploy the previous image first, then roll the schema back with the
migration version from `priv/repo/migrations`. Keep that order: a running
machine caches its migration status for its lifetime, so rolling the schema
back under the newer image would leave it reporting healthy while its code is
ahead of the database. Run the rollback from the newer image, in a one-off
machine: the previous image does not contain the migration being undone and
answers "Migrations already down" without changing anything:

```sh
fly console --app patchbay-regents \
  --image registry.fly.io/patchbay-regents:<newer image> \
  -C "/app/bin/patchbay eval 'Patchbay.Release.rollback(Patchbay.Repo, 20260901132657)'"
```

### Separate migration credentials

`Patchbay.Release.migrate()` connects through `DATABASE_DIRECT_URL`, read by
`Patchbay.DatabaseConfig.release_config!/0`, never through the serving
connection. Run migration commands in a fresh release `eval` process; they
refuse an already-running Repo and restore its configuration afterward. Local
`mix ecto.migrate` keeps its development configuration. The selected product
schema is retained. Existing imported
history must be present before selecting the shared product namespace.
