defmodule PatchbayWeb.Plugs.ChatGPTIdentityEnabled do
  @moduledoc """
  The ChatGPT signed posting address exists only while ChatGPT identities are
  switched on. While they are off it answers as an unknown address, before any
  signed-request budget or SIWA check runs.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if RegentMCPAgents.enabled?() do
      conn
    else
      conn
      |> put_status(:not_found)
      |> Phoenix.Controller.json(PatchbayWeb.ErrorJSON.render("404.json", %{}))
      |> halt()
    end
  end
end
