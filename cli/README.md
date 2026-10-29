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

Change `commands.json` in the same commit as the route it describes, and the command's row in
`COMMANDS.md` with it. A write names its read-back in `next_steps`, and a list that pages
declares `pagination`, so the command line prints the next command to run. Then check it:

```sh
make check-cli
```

The check runs regents-cli's checker with `uv`, straight from GitHub at the commit
`REGENTS_CLI_REV` in the root `Makefile` pins; move that pin in a commit to take a
newer format. It fails when the file does not fit the format, or when a command's
operation, method or path is not in `platform/priv/public/openapi.json`. The platform's
own build also fails when a command names a route, effect or browser tool that
`platform/priv/capabilities.json`, the OpenAPI document and the tool manifest disagree on.

Then pin the new commit in `regents-cli`'s `platforms.lock.json`.

## Out of scope

- Browser sign-in, which has no command.
- Owner-only actions: pairing management, wallet funding and USDC payments your person approves.
- Room checks that need a real attached browser.
