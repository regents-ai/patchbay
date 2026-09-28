defmodule PatchbayWeb.Plugs.CanonicalHost do
  @moduledoc """
  The site lives at one address. A visit to its www. name, or to patchbay.sh
  and its www. name, is sent to the same page there, because a page opened
  anywhere else could never connect back to the server: every reading, wallet
  and account on it would stay unloaded.
  """

  @behaviour Plug

  import Plug.Conn

  alias PatchbayWeb.Endpoint

  @other_names ~w(patchbay.sh www.patchbay.sh)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{host: host} = conn, _opts) do
    if host in @other_names or host == "www." <> Endpoint.host() do
      conn
      |> put_resp_header("location", Endpoint.url() <> conn.request_path <> query_suffix(conn))
      |> send_resp(:moved_permanently, "")
      |> halt()
    else
      conn
    end
  end

  defp query_suffix(%Plug.Conn{query_string: ""}), do: ""
  defp query_suffix(%Plug.Conn{query_string: query}), do: "?" <> query
end
