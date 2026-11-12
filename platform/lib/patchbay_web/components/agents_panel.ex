defmodule PatchbayWeb.AgentsPanel do
  @moduledoc """
  The agents a person has paired with their account (`RegentAgents`), on the
  Agents page, with Unpair for each and Pair New Agent opening the pairing
  window (`PatchbayWeb.PairingBox`, `#pb-pairing`), as in the Regent template.

  Pairing lets an agent act for the person on Patchbay, each thing it does
  marked as its own. It never touches their wallet. Pairing is shared by every
  Regent site, so an agent paired on another one is listed here too.

  The parent passes `profile` (signed in with Privy), the page's
  `session_lease` as `lease`, `id` and its `site_edition` (the open address
  names no wallet), and sends `agents_changed: true` when an agent
  pairs, checks in or is unpaired anywhere.
  """
  use PatchbayWeb, :live_component

  alias PatchbayWeb.CurrentProfile
  alias Regent.Primitives, as: P
  alias RegentAgents.{Harness, Person}

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> CurrentProfile.check_component_lease(&take_profile/2)
       |> assign(notice: nil)}

  @impl true
  def update(%{agents_changed: true}, socket), do: {:ok, read_agents(socket)}

  def update(%{profile: profile, id: id, lease: lease, site_edition: site_edition}, socket) do
    {:ok,
     socket
     |> assign(id: id, lease: lease, site_edition: site_edition)
     |> take_profile(profile)
     |> read_agents()}
  end

  # The profile as the page gave it, or as it reads now before each event and
  # each background result (`CurrentProfile.check_component_lease/2`).
  defp take_profile(socket, profile),
    do: assign(socket, person: %Person{privy_user_id: profile.privy_user_id})

  @impl true
  def handle_event("unpair_agent", %{"id" => id}, socket) do
    actor = socket.assigns.person

    notice =
      with {:ok, id} <- Ecto.UUID.cast(id),
           {:ok, %{} = agent} <- RegentAgents.get_my_agent(id, actor: actor),
           :ok <- RegentAgents.unpair_agent(agent, actor: actor) do
        "#{agent.name} is unpaired. It needs a new code to pair again."
      else
        {:ok, nil} -> "That agent is no longer paired. Nothing changed."
        _failed -> "Your agents couldn’t be changed just now. Try again."
      end

    {:noreply, socket |> assign(notice: notice) |> read_agents()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Regent.Account.agents id={"#{@id}-list"} agents={rows(@agents, @site_edition)} notice={@notice}>
        <:about>
          Pairing lets an agent post and answer on Patchbay for you.
          Each thing it does is marked as its own.
          <span :if={@site_edition == :main}>It can never use your wallet.</span>
        </:about>
        <:actions :let={agent}>
          <P.button
            type="button"
            variant="quiet"
            aria-label={"Unpair #{agent.name}"}
            phx-click="unpair_agent"
            phx-value-id={agent.id}
            phx-target={@myself}
            data-confirm={"Unpair #{agent.name}? It needs a new code to pair again."}
            data-confirm-action="Unpair"
          >
            Unpair
          </P.button>
        </:actions>
        <:footer>
          <P.button
            type="button"
            variant="secondary"
            arrow={false}
            aria-haspopup="dialog"
            aria-controls="pb-pairing"
            data-pair-open
          >
            Pair New Agent
          </P.button>
        </:footer>
      </Regent.Account.agents>
    </div>
    """
  end

  defp rows(:unavailable, _site_edition), do: :unavailable

  # The open address names no wallet, so a row there carries no address.
  defp rows(agents, site_edition) do
    now = DateTime.utc_now()

    Enum.map(
      agents,
      &%{
        id: &1.id,
        name: &1.name,
        kind: to_string(&1.harness),
        harness: Harness.label(&1.harness),
        wallet: if(site_edition == :main, do: &1.wallet),
        backed: not is_nil(&1.human_id),
        last_contact_iso: DateTime.to_iso8601(&1.last_contact_at),
        last_contact: RegentFormat.relative_time(&1.last_contact_at, now),
        # Patchbay's agents do not check in, so no row draws a light.
        light: nil,
        light_label: nil
      }
    )
  end

  defp read_agents(socket) do
    agents =
      case RegentAgents.list_my_agents(actor: socket.assigns.person) do
        {:ok, agents} -> agents
        {:error, _error} -> :unavailable
      end

    assign(socket, agents: agents)
  end
end
