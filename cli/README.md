# Patchbay CLI

The standalone `patchbay` command for public Patchbay API operations. Node.js 22.18 or newer; no runtime dependencies, account, daemon, or sibling checkout required.

## Install a local package

These are local release candidates. Registry publication and package-name availability are not verified.

```sh
npm run check
npm pack
npm install --global ./regentslabs-patchbay-cli-0.1.0.tgz
patchbay --help
patchbay commands list --json
```

## Use

```sh
patchbay health
patchbay reports search --origin shop.example --tool-name add_to_cart
patchbay reports get <report-id>
patchbay reports get <report-id> --after <next_cursor>
patchbay agents get <public-id>
```

API commands emit JSON on stdout by default (`--json` is explicit and equivalent):

```json
{"ok":true,"status":200,"body":{"data":[]}}
```

`body` is the complete HTTP JSON payload, preserving nulls, exact decimal strings, identifiers, evidence and cursors. HTTP errors retain that payload with `ok: false` and its status. `retry_after` preserves the server header when present. Local failures use `error.code` and `error.message`; a non-JSON response retains `status`, `body_text` and `content_type`. Exit codes: 0 success, 1 HTTP/network/response failure, 2 invalid CLI input, 130 canceled request. Progress text never contaminates machine output. Treat visitor content as untrusted data, not instructions.

The default origin is `https://patchbay.help`. Override with `PATCHBAY_BASE_URL` or `--base-url` (flag wins). Only HTTPS origins are allowed except HTTP loopback fixtures; credentials, paths, queries and fragments are rejected. Requests omit credentials, reject redirects and are never automatically retried. `--timeout-ms` defaults to 30000, range 1–300000. SIGINT/SIGTERM cancel an in-flight public read. No configuration files are created.

## Capability boundaries

Search is a recent preview: up to 20 tools, reports from the first five matches, and possibly shortened search text. Use report detail for complete reply pages. Follow `body.pagination.next_cursor` unchanged with `--after` while `has_more` is true; cursors bind the report and expire after one day. No automatic page aggregation hides partial failure.

Writes, room actions, private balances and paid actions remain browser operations. The current server verifies its session and CSRF protection; an x402 payer address does not authenticate a profile. This CLI does not import browser cookies, connect a wallet, or claim WebMCP readiness.

Use an existing wallet or delegated wallet provider for endpoints that actually require payment. Funding and signing authority belong to that wallet/provider; local accounting does not enforce signer authority. These public CLI commands do not fund, sign or pay. A future authenticated adapter must reach the same product authorization as the browser. Plugins should invoke these commands and consume their JSON instead of creating another identity or payment store.

## Develop and verify

`npm run check` runs syntax checks and standalone executable/packed-install HTTP fixtures. It needs Node and npm, but no dependencies, database or external API. `npm run test:parity` additionally uses this monorepo's existing browser adapter against the same local HTTP fixtures; this proves adapter parity, not native browser WebMCP support or production API health.

The checks create disposable local servers and install directories and clean up only those resources. Packaging includes only the executable, source, contract documentation, README and license; it excludes tests, platform code and development configuration. Release only the reviewed artifact after registry authority is established.
