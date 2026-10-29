defmodule PatchbayWeb.Plugs.EventReader do
  @moduledoc """
  OAuth authority for ChatGPT event subscription methods only. A missing or
  refused token is answered 401 with the OAuth challenge, which starts a
  client's sign-in; event sign-in that is off or failing is answered in
  JSON-RPC (`PatchbayWeb.MCP.Refusal`).
  """
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
      unavailable(conn, "Watching updates from ChatGPT is not switched on yet.")
    end
  rescue
    _ -> unavailable(conn, "Watching updates from ChatGPT is not working right now.")
  end

  # Nothing the client can sign in to: answered in JSON-RPC, like every other
  # refusal at this address, rather than as a failed connection.
  defp unavailable(conn, message),
    do:
      PatchbayWeb.MCP.Refusal.refuse(conn, %{
        code: "unavailable",
        message: message,
        hint: "Read threads with search_threads and get_thread meanwhile, and try again later."
      })

  defp refuse(conn, status, message) do
    conn
    |> put_resp_header("www-authenticate", RegentOAuth.challenge())
    |> RegentOAuth.Protocol.json(status, %{
      jsonrpc: "2.0",
      id: conn.body_params["id"],
      error: %{code: -32_001, message: message}
    })
    |> halt()
  end
end
