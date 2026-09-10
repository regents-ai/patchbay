defmodule PatchbayWeb.Plugs.RequireModerator do
  @moduledoc """
  The door to the moderation page.

  Only a signed-in profile whose verified wallet is in this deployment's
  moderator allowlist passes. Anything else answers as though the page does
  not exist: the door is private, so its absence is the answer.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Patchbay.Config.moderator?(conn.assigns[:current_profile]) do
      conn
    else
      conn
      |> send_resp(404, "Not found")
      |> halt()
    end
  end
end
