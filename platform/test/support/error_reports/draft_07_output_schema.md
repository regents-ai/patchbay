Claude Desktop rejects every MCP tool: "outputSchema ... unsupported dialect (draft-07)". Cause and working fix

**Error** (Claude Desktop and Cowork; the Claude Code CLI was not affected when last tested):

    Tool 'count' has an invalid outputSchema: JSON Schema declares an unsupported dialect
    ("$schema": "http://json-schema.org/draft-07/schema#"). The default validator supports
    JSON Schema 2020-12 only; pass a pre-configured Ajv instance to AjvJs

Every tool on the server fails before the call reaches it.

**Versions seen:** Claude Desktop 1.37937.1, 1.52386.3, 2.7032.0, updater 2.9939.4.
Servers built with `@modelcontextprotocol/sdk` 1.29.0 to 1.32.1 (server-filesystem 2026.7.4 to
2026.8.31, Anthropic's Filesystem extension, mongodb-mcp-server, MongoDB Atlas, Roam, Veeam and
more).

**Cause:** the app validates `outputSchema` with the MCP SDK v2 default validator, which
accepts only JSON Schema 2020-12 and refuses any other declared `$schema`. `McpServer` in SDK
1.x always declares draft-07 (typescript-sdk issue 2721).

**Reproduction (no app needed, 27 Oct 2026, Node 26.8.1):** a server built with
`@modelcontextprotocol/sdk` 1.29.0 and zod 4.4.3 registers `count` with an `outputSchema`; its
`tools/list` answer carries `"$schema": "http://json-schema.org/draft-07/schema#"`.
`new AjvJsonSchemaValidator().getValidator(schema)` from `@modelcontextprotocol/server`
2.0.0-beta.2 throws the error above. With `$schema` deleted the same schema is accepted and
still validates (`{"total":3}` passes, `{"total":"x"}` fails). Converted with
`target: "draft-2020-12"` it is accepted too.

**Fix for users (confirmed by several reporters):** run the server behind a small stdio proxy
that removes `$schema` from each tool's `inputSchema` and `outputSchema` in the `tools/list`
answer, configured in `claude_desktop_config.json` with the built-in extension switched off.
Watch out with server-filesystem: recent versions replace your configured folders with the
roots the app announces, so check `list_allowed_directories` after the tools load.

**Fix for server authors:** publish `outputSchema` without `$schema`, or with
`https://json-schema.org/draft/2020-12/schema`. `McpServer` 1.x has no option for this yet.

**Still open:** the app accepting draft-07, or the SDK change in typescript-sdk 2721.

Evidence: anthropics/claude-code issues 86142, 94351, 88882; modelcontextprotocol/typescript-sdk
issue 2721; anthropics/claude-ai-mcp issue 1016.
