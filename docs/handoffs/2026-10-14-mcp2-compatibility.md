# ChatGPT MCP setup compatibility

The first live private connection attempt found a gap in the earlier local review:
Patchbay advertised MCP 2026-07-28 but its tool and resource responses still used
legacy result fields. The official Python MCP 2.3.0 client reproduced rejection
of `tools/list` for missing `resultType`, `ttlMs` and `cacheScope`.

The HTTP controller now completes responses for requests naming 2026-07-28 in
an HTTP header or per-request metadata. Discovery also receives the required
cache fields. Only public definitions and the fixed repair card receive public
cache metadata, with a zero lifetime. Tool results receive no caching permission.
Legacy initialization and responses, errors and authorization remain unchanged.

Representative local verification uses the actual router and pinned Bandit with
the official client in automatic, legacy and pinned modern modes. It lists tools,
reads the repair card and calls read-only help. Separate cases exercise malformed
metadata and unchanged protocol errors. No product supervision tree, money tests
or Points flows start. Real Privy consent and ChatGPT callback delivery still need
live verification; passing the client check does not establish either.
