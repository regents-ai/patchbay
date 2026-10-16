defmodule PatchbayWeb.PanelAgents do
  @moduledoc """
  The agents paired with the person's account (`RegentAgents`), first in the side
  panel on every page, in the shared short list (`Regent.Account.agents_brief`):
  each agent's picture and name over the Regent site it was last active on and
  how long ago, as in the Regent template. Pairing is shared by every Regent
  site, so an agent paired on another one is listed too. "Your agents" links to
  the Account page, whose list (`PatchbayWeb.AgentsPanel`) unpairs them; the
  shared list draws its heading as plain text, so the link stands in its place
  and the list keeps its own heading as its name.

  Where each agent was last active comes from its shared reading
  (`Patchbay.Agents.ActivityReading`), asked for only for an open panel: the
  `PanelAgents` hook asks when the page arrives with the panel open and each time
  it opens, and a request while one is still out is let go. A pairing, check-in
  or unpairing updates the list at once; the lines follow on the next opening.

  The parent passes `profile` (signed in with Privy), its `session_lease` as
  `lease` and `id`, and sends `agents_changed: true` when an agent pairs, checks
  in or is unpaired anywhere.
  """
  use PatchbayWeb, :live_component

  alias Patchbay.Agents.ActivityReading
  alias PatchbayWeb.CurrentProfile
  alias RegentAgents.{Activity, Person}

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> CurrentProfile.check_component_lease(&take_profile/2)
       |> assign(last_actions: %{}, reading: false)}

  @impl true
  def update(%{agents_changed: true}, socket), do: {:ok, read_agents(socket)}

  def update(%{profile: profile, id: id, lease: lease}, socket),
    do: {:ok, socket |> assign(id: id, lease: lease) |> take_profile(profile) |> read_agents()}

  # The profile as the page gave it, or as it reads now before each event
  # (`CurrentProfile.check_component_lease/2`).
  defp take_profile(socket, profile),
    do: assign(socket, person: %Person{privy_user_id: profile.privy_user_id})

  @impl true
  def handle_event("read_last_actions", _params, socket),
    do: {:noreply, read_last_actions(socket)}

  @impl true
  def handle_async(:last_actions, {:ok, last_actions}, socket),
    do:
      {:noreply,
       assign(socket, last_actions: last_actions, reading: false, now: DateTime.utc_now())}

  def handle_async(:last_actions, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, reading: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"#{@id}-reader"} class="pb-panel-agents" phx-hook="PanelAgents" data-read-on-open>
      <h2 class="pb-panel-agents__title"><a href={~p"/account"}>Your agents</a></h2>
      <Regent.Account.agents_brief id={@id} agents={rows(@agents, @last_actions, @now)} />
    </div>
    """
  end

  defp read_agents(socket) do
    agents =
      case RegentAgents.list_my_agents(actor: socket.assigns.person) do
        {:ok, agents} -> agents
        {:error, _error} -> :unavailable
      end

    assign(socket, agents: agents, now: DateTime.utc_now())
  end

  defp read_last_actions(%{assigns: %{reading: false, agents: agents}} = socket)
       when is_list(agents),
       do:
         socket
         |> assign(reading: true)
         |> start_async(:last_actions, fn -> last_actions(agents) end)

  defp read_last_actions(socket), do: socket

  # Where and when each agent was last active, by id; an agent whose reading
  # fails or crashes, or that has not been active since it paired, is left out,
  # and its line stays empty. The reads are not linked to the page, so one that
  # crashes ends only itself.
  defp last_actions(agents) do
    Patchbay.Agents.Reads
    |> Task.Supervisor.async_stream_nolink(agents, &{&1.id, last_action(&1)},
      max_concurrency: 4,
      timeout: 8_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {id, %{} = latest}} -> [{id, latest}]
      _unread -> []
    end)
    |> Map.new()
  end

  defp last_action(agent) do
    case ActivityReading.read(agent) do
      {:ok, reading} -> Activity.latest(reading)
      {:error, _reason} -> nil
    end
  end

  defp rows(:unavailable, _last_actions, _now), do: :unavailable

  defp rows(agents, last_actions, now) do
    Enum.map(agents, fn agent ->
      latest = last_actions[agent.id]

      %{
        id: agent.id,
        name: agent.name,
        kind: to_string(agent.harness),
        last_action: latest && "Active on #{latest.site}",
        last_action_iso: latest && DateTime.to_iso8601(latest.at),
        last_action_at: latest && RegentFormat.short_relative_time(latest.at, now)
      }
    end)
  end
end
