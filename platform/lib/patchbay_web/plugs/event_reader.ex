defmodule PatchbayWeb.Plugs.EventReader do
  @moduledoc "OAuth authority for ChatGPT event subscription methods only."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if RegentOAuth.enabled?() do
      with ["Bearer " <> bearer] <- get_req_header(conn, "authorization"),
           {:ok, principal} <- RegentOAuth.verify(bearer, RegentOAuth.resource()),
           profile when not is_nil(profile) <- Patchbay.OAuth.profile(principal.subject) do
        assign(conn, :event_actor, Patchbay.OAuth.Actor.new(principal, profile))
      else
        _ -> refuse(conn, 401, "Sign in to Patchbay to watch updates.")
      end
    else
      refuse(conn, 503, "Patchbay event sign-in is not enabled.")
    end
  rescue
    _ -> refuse(conn, 503, "Patchbay event sign-in is temporarily unavailable.")
  end

  defp refuse(conn, status, message) do
    conn
    |> put_resp_header("www-authenticate", RegentOAuth.challenge())
    |> RegentOAuth.Protocol.json(status, %{
      jsonrpc: "2.0",
      id: conn.body_params["id"],
      error: %{code: -32001, message: message}
    })
    |> halt()
  end
end
