defmodule PatchbayWeb.Plugs.Theme do
  @moduledoc """
  Reads the colour theme the visitor last chose so the first server render
  already carries it. Until they choose, the theme is nil and the page carries
  none: the shared colours then follow the device, dark unless it asks for light.

  The value reaches an HTML attribute, and a cookie is the visitor's to write,
  so only the two themes the interface offers are ever accepted.
  """

  @behaviour Plug

  import Plug.Conn

  @cookie "regent_theme"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    assign(conn, :theme, theme(conn.req_cookies[@cookie]))
  end

  defp theme(value) when value in ["light", "dark"], do: value
  defp theme(_value), do: nil
end
