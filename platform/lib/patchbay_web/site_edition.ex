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

  The process serving a request or a LiveView also keeps its edition, as
  Gettext keeps a locale, for words drawn far from the connection that differ
  by address, such as the name of a person who chose none
  (`Patchbay.Identity.AgentProfile.own_name/1`).
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

  @doc """
  The page tools an edition does not offer: at the open address, every one
  whose route answers only at patchbay.help (`only: :main` in the router), such
  as each Offer, Credits and Points tool. A page names them so its WebMCP tools
  leave them out, and the page's help lists none of them.
  """
  @spec left_out_tools(t()) :: [String.t()]
  def left_out_tools(edition),
    do: for(tool <- Patchbay.Forum.Capabilities.site(), not offers?(edition, tool), do: tool.name)

  @doc """
  Whether `edition`'s address offers `tool`, a manifest row: at the open
  address, not when its route answers only at patchbay.help.
  """
  @spec offers?(t(), map()) :: boolean()
  def offers?(:main, _tool), do: true

  def offers?(:open, %{route: route}) do
    [verb, path] = String.split(route, " ")
    not main_only?(verb, String.replace(path, ~r/\{[a-z_]+\}/, "x"))
  end

  @doc "Whether the route `verb` and `path` reach answers only at patchbay.help (`only: :main` in the router)."
  @spec main_only?(String.t(), String.t()) :: boolean()
  def main_only?(verb, path) do
    case Phoenix.Router.route_info(PatchbayWeb.Router, verb, path, open_host()) do
      %{pipe_through: pipelines} -> :main_only in pipelines
      :error -> false
    end
  end

  @impl Plug
  def init(:assign), do: :assign
  def init(only: edition) when edition in [:main, :open], do: {:only, edition}

  @doc "The edition of the request or LiveView this process is serving."
  @spec current() :: t()
  def current do
    case Process.get(__MODULE__) do
      edition when edition in [:main, :open] -> edition
    end
  end

  @doc "Keeps `edition` as the one this process is serving (`current/0`)."
  @spec put(t()) :: t() | nil
  def put(edition) when edition in [:main, :open], do: Process.put(__MODULE__, edition)

  @impl Plug
  def call(conn, :assign) do
    edition = if conn.host == open_host(), do: :open, else: :main
    put(edition)
    assign(conn, :site_edition, edition)
  end

  def call(conn, {:only, edition}) do
    conn.assigns.site_edition == edition or raise PatchbayWeb.Forum.NotFoundError
    conn
  end

  def on_mount(:default, _params, session, socket) do
    edition = Map.fetch!(session, "site_edition")
    put(edition)
    {:cont, Phoenix.Component.assign(socket, :site_edition, edition)}
  end

  def on_mount(edition, _params, session, socket) when edition in [:main, :open] do
    if Map.fetch!(session, "site_edition") == edition,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
