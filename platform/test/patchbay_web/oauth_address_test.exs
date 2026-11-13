defmodule PatchbayWeb.OAuthAddressTest do
  @moduledoc """
  Connected-app sign-in lives only at the open address. At patchbay.help its
  register, token and revoke addresses say where it lives, in OAuth's error
  shape, and use nothing the request sent.
  """

  # It switches connected-app sign-in on for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  alias Boruta.Ecto.Client
  alias Boruta.Ecto.Token
  alias Patchbay.Repo
  alias PatchbayWeb.SiteEdition

  @paths ~w(/oauth/register /oauth/token /oauth/revoke)
  @secret "rt-#{String.duplicate("s", 40)}"

  setup do
    oauth = Application.fetch_env!(:patchbay, Patchbay.OAuth)
    Application.put_env(:patchbay, Patchbay.OAuth, Keyword.put(oauth, :enabled?, true))
    on_exit(fn -> Application.put_env(:patchbay, Patchbay.OAuth, oauth) end)

    {:ok, client} =
      Boruta.Ecto.Admin.Clients.create_client(%{
        name: "ChatGPT",
        redirect_uris: ["https://chatgpt.com/connector/oauth/callback"],
        confidential: false,
        pkce: true,
        supported_grant_types: ["authorization_code", "refresh_token", "revoke"]
      })

    %{client: client}
  end

  test "at patchbay.help each address names its own at the open address, whatever is sent",
       %{conn: conn, client: client} do
    for path <- @paths do
      before = rows()
      garbage = "{{ not an oauth request %%"

      unread =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(path, garbage)

      plausible = post(conn, path, plausible(path, client))

      assert rows() == before

      # The malformed body is still waiting to be read: nothing looked at it.
      assert {:ok, ^garbage, _} = Plug.Conn.read_body(unread)

      for answer <- [unread, plausible] do
        assert get_resp_header(answer, "cache-control") == ["no-store"]
        assert get_resp_header(answer, "pragma") == ["no-cache"]
        refute answer.resp_body =~ client.id
        refute answer.resp_body =~ @secret

        assert %{"error" => "invalid_request", "error_description" => description} =
                 json_response(answer, 404)

        assert description =~ SiteEdition.url(:open) <> path
      end

      assert unread.resp_body == plausible.resp_body
    end
  end

  test "the same request at the open address reaches connected-app sign-in", %{conn: conn} do
    before = Repo.aggregate(Client, :count)

    assert %{"client_id" => _} =
             conn
             |> on_open()
             |> post("/oauth/register", plausible("/oauth/register", nil))
             |> json_response(201)

    assert Repo.aggregate(Client, :count) == before + 1

    assert conn
           |> post("/oauth/register", plausible("/oauth/register", nil))
           |> json_response(404)

    assert Repo.aggregate(Client, :count) == before + 1
  end

  test "at patchbay.help the addresses keep their rate limit", %{conn: conn} do
    conn = %{conn | remote_ip: {10, 77, :rand.uniform(250), :rand.uniform(250)}}

    for _ <- 1..30, do: assert(conn |> post("/oauth/register") |> response(404))

    assert conn |> post("/oauth/register") |> json_response(429) == %{"error" => "rate_limited"}
  end

  test "at patchbay.help a read of these addresses is still a missing page", %{conn: conn} do
    missing = conn |> get("/oauth/nothing-here") |> response(404)
    for path <- @paths, do: assert(conn |> get(path) |> response(404) == missing)
  end

  defp rows, do: {Repo.aggregate(Client, :count), Repo.aggregate(Token, :count)}

  defp plausible("/oauth/register", _client),
    do: %{
      "client_name" => "ChatGPT",
      "redirect_uris" => ["https://chatgpt.com/connector/oauth/callback"]
    }

  defp plausible("/oauth/token", client),
    do: %{"grant_type" => "refresh_token", "client_id" => client.id, "refresh_token" => @secret}

  defp plausible("/oauth/revoke", client),
    do: %{"client_id" => client.id, "token" => @secret, "token_type_hint" => "refresh_token"}
end
