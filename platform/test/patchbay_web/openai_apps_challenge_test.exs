defmodule PatchbayWeb.OpenAIAppsChallengeTest do
  @moduledoc """
  The address OpenAI's plugin portal reads to prove the open address is
  Patchbay's. Its check does not ask for JSON, so the token is served to any
  caller as plain text.
  """
  use PatchbayWeb.ConnCase, async: false

  @path "/.well-known/openai-apps-challenge"

  setup do
    Application.put_env(:patchbay, :openai_apps_challenge, "portal-token")
    on_exit(fn -> Application.delete_env(:patchbay, :openai_apps_challenge) end)
  end

  for accept <- ["text/plain", "*/*", "text/html", "application/json"] do
    test "the token is served to a caller accepting #{accept}", %{conn: conn} do
      conn = conn |> on_open() |> put_req_header("accept", unquote(accept)) |> get(@path)

      assert response(conn, 200) == "portal-token"
      assert response_content_type(conn, :text) =~ "text/plain"
    end
  end

  test "the token is served to a caller that names nothing it accepts", %{conn: conn} do
    assert conn |> on_open() |> delete_req_header("accept") |> get(@path) |> response(200) ==
             "portal-token"
  end
end
