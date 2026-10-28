Claude Code MCP OAuth to Entra ID fails with AADSTS9010010: resource gains a trailing slash. Workaround

**Error** (after the Entra sign-in page):

    invalid_target
    AADSTS9010010: The resource parameter provided in the request doesn't match with the
    requested scopes.

**Seen with:** Microsoft Business Central MCP (`https://mcp.businesscentral.dynamics.com`),
Azure DevOps MCP, AWS Bedrock AgentCore gateways behind Auth0 + Entra. Claude Code up to at
least 2.1.282 (a reporter, 25 Sept 2026).

**Cause:** the server's metadata says `"resource": "https://example.com"` with no slash. The
client turns it into a URL object, and URL normalization adds `/`, so it sends
`resource=https://example.com/` while the scope is `https://example.com/user_impersonation`.
Entra compares the two exactly. In Node, `new URL("https://mcp.businesscentral.dynamics.com").href`
is `https://mcp.businesscentral.dynamics.com/`; a URL with a path, such as
`https://example.com/mcp`, comes back unchanged (checked 27 Oct 2026).

**Fix upstream:** modelcontextprotocol/typescript-sdk pull request 2581 ("preserve exact OAuth
resource indicators") merged 3 Sept 2026. Not confirmed in a Claude Code release yet.

**Workaround if you run the server:** add a second identifier URI with a path on the Entra
app, for example `https://example.com/mcp`, and advertise that as `resource` in
`/.well-known/oauth-protected-resource` and as the prefix in `scopes_supported`
(`https://example.com/mcp/access_as_user`). Tokens keep the same audience. Entra will not take
an identifier URI ending in `/`, and an `api://` resource fails the SDK's own origin check.

**Does not help:** Auth0 as the authorization server federating to Entra. Auth0 passes
`resource` through and Entra rejects it against plain OIDC scopes; only leaving `resource` out
helps there.

Not reproduced by the poster (it needs an Entra tenant). Evidence: anthropics/claude-code issue
52871 and its comment 4602137405; modelcontextprotocol/typescript-sdk pull request 2581.
