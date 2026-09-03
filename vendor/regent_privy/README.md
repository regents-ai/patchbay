# RegentPrivy

Shared Privy identity-token verification for Regent Elixir apps.

`RegentPrivy.verify_token/2` verifies the ES256 signature against the app's
Privy verification key, validates issuer, audience, and time claims, and
returns the verified claims, the Privy user id, and normalized linked wallet
addresses. Apps pass their own Privy configuration per call:

```elixir
RegentPrivy.verify_token(token,
  app_id: "my-privy-app-id",
  verification_key: pem
)
#=> {:ok, %{claims: %{...}, privy_user_id: "did:privy:...",
#=>         wallet_address: "0x...", wallet_addresses: ["0x..."]}}
```

This library holds no configuration or secrets and never logs token contents.
