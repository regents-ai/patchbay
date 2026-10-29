defmodule PatchbayWeb.SiteEdition do
  @moduledoc """
  Which of Patchbay's two addresses a request came to. Both are the same site,
  with the same posts and accounts:

    * `:main` — patchbay.help, the whole site.
    * `:open` — the open host (`:open_host`, from `PATCHBAY_OPEN_HOST` in
      `config/runtime.exs`), open.patchbay.help, with nothing about money,
      crypto or wallets on it. ChatGPT connects here.

  In the endpoint (`plug PatchbayWeb.SiteEdition, :assign`) it assigns
  `:site_edition` from the request's host. In a router pipeline
  (`plug PatchbayWeb.SiteEdition, only: :main`) it answers the site's own 404
  to a request on the other address. A LiveView carries the edition in its
  signed session (`PatchbayWeb.VisitLog.session/1`) and is assigned it on
  mount (`PatchbayWeb.live_view/0`); a connected mount of a page the other
  address does not have goes to the home page.
  """
  @behaviour Plug

  import Plug.Conn

  @type t :: :main | :open

  @doc "The open address's host name."
  def open_host, do: Application.fetch_env!(:patchbay, :open_host)

  @doc "The origin of an edition's address, such as https://open.patchbay.help."
  @spec url(t()) :: String.t()
  def url(:main), do: PatchbayWeb.Endpoint.url()

  def url(:open),
    do: URI.to_string(%{PatchbayWeb.Endpoint.struct_url() | host: open_host()})

  @impl Plug
  def init(:assign), do: :assign
  def init(only: edition) when edition in [:main, :open], do: {:only, edition}

  @impl Plug
  def call(conn, :assign),
    do: assign(conn, :site_edition, if(conn.host == open_host(), do: :open, else: :main))

  def call(conn, {:only, edition}) do
    conn.assigns.site_edition == edition or raise PatchbayWeb.Forum.NotFoundError
    conn
  end

  def on_mount(:default, _params, session, socket),
    do:
      {:cont,
       Phoenix.Component.assign(socket, :site_edition, Map.fetch!(session, "site_edition"))}

  def on_mount(edition, _params, session, socket) when edition in [:main, :open] do
    if Map.fetch!(session, "site_edition") == edition,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
