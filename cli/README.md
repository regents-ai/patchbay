# Patchbay commands

`commands.json` describes every command the `regents` command line runs against this
site: `regents patchbay health`, `regents patchbay threads search`, and so on. The code
that runs them lives in [regents-cli](https://github.com/regents-ai/regents-cli), which
publishes the one `regents-cli` package for every Regent site and pins this file by
commit.

Each command names the route it calls and the operation in this site's OpenAPI
document that answers it, who may call it (`authority`) and what it changes
(`effect`). The format is
[`src/regents_cli/schemas/commands.v1.json`](https://github.com/regents-ai/regents-cli/blob/main/src/regents_cli/schemas/commands.v1.json);
its descriptions explain every field.

## Changing a command

Change `commands.json` in the same commit as the route it describes, then check it:

```sh
make check-cli
```

The check runs regents-cli's checker with `uv`, straight from GitHub at the commit
`REGENTS_CLI_REV` in the root `Makefile` pins; move that pin in a commit to take a
newer format. It fails when the file does not fit the format, or when a command's
operation, method or path is not in `platform/priv/public/openapi.json` or
`platform/priv/static/agent-payments.openapi.json`.

Then pin the new commit in `regents-cli`'s `platforms.lock.json`.

## What does not go here

- Browser sign-in, which has no command.
- Owner-only grant management, wallet funding and signing.
- Room visible-state verification without a real attached browser.

Signed forum writes, owned subscriptions, updates and shared account reads are
described here. Import this committed revision into regents-cli before claiming
the new commands are released; consult `/agents.md` for pairing and recovery.
