defmodule PatchbayWeb.OAuthAddressTest do
  @moduledoc """
  Each address has its own connected-app sign-in (`Patchbay.OAuth`): the open
  address's for the ChatGPT plugin, patchbay.help's for every other app. Each
  is its own issuer for its own MCP address, each answers only while it is
  switched on, and a token one issued is refused at the other.
  """

  # It switches connected-app sign-in on for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  alias Boruta.Ecto.Token
  alias PatchbayWeb.SiteEdition

  @paths ~w(/oauth/register /oauth/token /oauth/revoke)

  test "while patchbay.help's sign-in is off it is not found there, and the open address's answers",
       %{conn: conn} do
    Patchbay.OAuthSwitch.on(:open)

    for path <- @paths do
      assert conn |> post(path, %{}) |> response(404)
    end

    assert conn |> get("/.well-known/oauth-authorization-server") |> response(404)

    assert %{"issuer" => "https://open.patchbay.help"} =
             conn
             |> on_open()
             |> get("/.well-known/oauth-authorization-server")
             |> json_response(200)
  end

  test "each address names itself as issuer and its own MCP address as resource", %{conn: conn} do
    Patchbay.OAuthSwitch.on(:open)
    Patchbay.OAuthSwitch.on(:main)
    main = SiteEdition.within(:main, &RegentOAuth.issuer/0)

    server = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert server["issuer"] == main
    assert server["authorization_endpoint"] == main <> "/oauth/authorize"
    assert server["client_id_metadata_document_supported"] == true

    assert server["scopes_supported"] == [
             RegentMCPAgents.identity_scope(),
             RegentMCPAgents.posting_scope()
           ]

    for path <-
          ~w(/.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp) do
      resource = conn |> get(path) |> json_response(200)
      assert resource["resource"] == main <> "/mcp"
      assert resource["authorization_servers"] == [main]
    end

    open =
      conn |> on_open() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert open["issuer"] == "https://open.patchbay.help"
    refute Jason.encode!(open) =~ main
  end

  test "a token from one address is refused at the other", %{conn: conn} do
    Patchbay.OAuthSwitch.on(:open)
    Patchbay.OAuthSwitch.on(:main)

    {:ok, client} =
      Boruta.Ecto.Admin.Clients.create_client(%{
        name: "Claude",
        redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
        confidential: false,
        pkce: true,
        supported_grant_types: ["authorization_code", "refresh_token", "revoke"]
      })

    profile =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:issuer-#{System.unique_integer([:positive])}",
        wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      })

    from_open = token!(client, profile, :open, "patchbay.events.read")
    from_main = token!(client, profile, :main, RegentMCPAgents.identity_scope())

    # Each verifies at its own address only.
    for {bearer, edition} <- [{from_open, :open}, {from_main, :main}] do
      assert {:ok, _} = verify(bearer, edition, scope(edition))
      assert {:error, :unauthorized} = verify(bearer, other(edition), scope(edition))
    end

    # The open address's MCP address sends the main token to sign in again.
    refused =
      conn
      |> on_open()
      |> put_req_header("authorization", "Bearer " <> from_main)
      |> put_req_header("content-type", "application/json")
      |> post("/chatgpt/mcp", rpc("events/subscribe"))

    assert refused.status == 401
    assert [challenge] = get_resp_header(refused, "www-authenticate")
    assert challenge =~ "https://open.patchbay.help/.well-known/oauth-protected-resource"
  end

  defp scope(:open), do: "patchbay.events.read"
  defp scope(:main), do: RegentMCPAgents.identity_scope()

  defp other(:open), do: :main
  defp other(:main), do: :open

  defp verify(bearer, edition, scope),
    do:
      SiteEdition.within(edition, fn ->
        RegentOAuth.verify(bearer, RegentOAuth.resource(), scope)
      end)

  # A live access token issued at `edition`, as its token endpoint leaves it.
  defp token!(client, profile, edition, scope) do
    bearer = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    token =
      Patchbay.Repo.insert!(%Token{
        type: "access_token",
        value: RegentOAuth.hash_token(bearer),
        client_id: client.id,
        sub: profile.privy_user_id,
        scope: scope,
        expires_at: System.system_time(:second) + 3600
      })

    :ok = SiteEdition.within(edition, fn -> RegentOAuth.bind(token.id) end)
    bearer
  end

  defp rpc(method),
    do: Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: %{}})
end
