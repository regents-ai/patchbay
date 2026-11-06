defmodule PatchbayWeb.PairLive do
  @moduledoc """
  The page a "Pair New Agent" link opens: `/pair?to=<path>`, where `to` is a
  page on this site, as in the Regent template. A person pairs their agent in
  the same pairing box as the pairing window's (`PatchbayWeb.PairingBox`), and
  the message they paste ends by sending the agent to that page once it is
  paired. A link with no `to`, or one that is not a page on this site, opens
  plain pairing.
  """
  use PatchbayWeb, :live_view

  # A page on this site: one leading "/", never "//" or "/\", which browsers read
  # as another site, and no spaces or control characters.
  @page ~r|\A/(?![/\\])[^\s\\\x00-\x1f\x7f]{0,511}\z|u

  @impl true
  def mount(_params, _session, socket) do
    with %{privy_user_id: did} <- socket.assigns.current_profile,
         true <- connected?(socket),
         do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))

    {:ok, assign(socket, PatchbayWeb.PublicDocuments.page("/pair"))}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, start: start(params))}

  @doc "The page a pairing link names, or nil when it names none on this site."
  @spec start(map()) :: String.t() | nil
  def start(%{"to" => to}) when is_binary(to), do: if(to =~ @page, do: to)
  def start(_params), do: nil

  @impl true
  def handle_info(:agents_changed, socket) do
    send_update(PatchbayWeb.PairingBox, id: "pair-pairing-box", agents_changed: true)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="pair-page" class="patchbay-shell pb-account-page pair-page">
      <header class="pb-account-heading">
        <h1 tabindex="-1">{@page_title}</h1>
      </header>
      <p :if={@start} id="pair-start">
        Once paired, it starts at
        <a href={@start}>{PatchbayWeb.SiteEdition.url(@site_edition) <> @start}</a>
      </p>
      <section
        :if={is_nil(@current_profile)}
        id="pair-signed-out"
        class="rg-account rg-account--signed-out"
      >
        <p>Sign in to pair your agent.</p>
        <Regent.Primitives.button variant="primary" type="button" data-account-target="sign-in">
          Sign in
        </Regent.Primitives.button>
      </section>
      <.live_component
        :if={@current_profile}
        module={PatchbayWeb.PairingBox}
        id="pair-pairing-box"
        lease={@session_lease}
        profile={@current_profile}
        site_edition={@site_edition}
        start={@start}
      />
    </main>
    """
  end
end
