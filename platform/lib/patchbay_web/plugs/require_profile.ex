defmodule PatchbayWeb.Plugs.RequireProfile do
  @moduledoc """
  Stops an API request that has no signed-in profile behind it.

  Payment endpoints act on behalf of one profile and no other, so there is no
  anonymous version of them to fall through to: without a profile the request
  ends here with a 401 the caller can act on.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:current_profile] do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: "Sign in on this page to do that.",
            problem_code: "sign_in_required",
            next_action:
              "Ask the human to sign in on the current Patchbay page. Never ask for wallet secrets.",
            payment_help_url: "#{PatchbayWeb.Endpoint.url()}/agent-setup#x402"
          })
        )
        |> halt()

      _profile ->
        conn
    end
  end
end
