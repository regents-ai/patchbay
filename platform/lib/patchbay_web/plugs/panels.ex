defmodule PatchbayWeb.Plugs.Panels do
  @moduledoc """
  Reads whether the visitor left the side panel open, so the first server render
  already draws it that way: closed until they choose otherwise. The browser
  writes the cookie (`assets/js/hooks/side_panel.ts`); only the two values the
  panel can take are ever accepted, since they reach an HTML attribute.
  """

  @behaviour Plug

  import Plug.Conn

  @cookie "patchbay_aside"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    assign(conn, :aside, aside(conn.req_cookies[@cookie]))
  end

  defp aside("open"), do: "open"
  defp aside(_value), do: "closed"
end
