defmodule PatchbayWeb.MenuAgents do
  @moduledoc """
  The three most recently active agents paired with the person's account
  (`RegentAgents`), in the account menu every page opens from its header, in the
  shared short list (`Regent.Account.agents_brief`), as in the Regent template:
  each agent's picture and name over the Regent site it was last active on and
  how long ago. Pairing is shared by every Regent site, so an agent paired on
  another one is listed too. Manage beside the heading opens this site's own Agents
  page, where every agent is listed.

  Where each agent was last active comes from its shared reading
  (`Patchbay.Agents.ActivityReading`), asked for only for an open menu: the
  `MenuAgents` hook asks each time the menu opens, and a request while one is
  still out is let go. Until the readings arrive the newest paired three show;
  then the three most recently active, with agents never active after those that
  were, newest paired first. A pairing, check-in or unpairing updates the list at
  once; the lines follow on the next opening.

  The parent passes `profile` (signed in with Privy), its `session_lease` as
  `lease` and `id`, and sends `agents_changed: true` when an agent pairs, checks
  in or is unpaired anywhere.
  """
  use PatchbayWeb, :live_component

  require Logger

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
    <div id={"#{@id}-reader"} phx-hook="MenuAgents">
      <Regent.Account.agents_brief
        id={@id}
        manage_href={~p"/account/agents"}
        agents={rows(@agents, @last_actions, @now)}
      />
    </div>
    """
  end

  defp read_agents(socket) do
    agents =
      case RegentAgents.list_my_agents(actor: socket.assigns.person) do
        {:ok, agents} ->
          agents

        {:error, error} ->
          Logger.warning(
            "The agents for the account menu couldn't be read: #{inspect(failure_kinds(error))}"
          )

          :unavailable
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

  # Where and when each agent was last active, by id, or `:none` for one not
  # active since it paired; an agent whose reading fails or crashes is left out,
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
      {:ok, {id, {:ok, latest}}} -> [{id, latest || :none}]
      _unread -> []
    end)
    |> Map.new()
  end

  defp last_action(agent) do
    case ActivityReading.read(agent) do
      {:ok, reading} -> {:ok, Activity.latest(reading)}
      {:error, _reason} -> :error
    end
  end

  defp rows(:unavailable, _last_actions, _now), do: :unavailable

  defp rows(agents, last_actions, now) do
    agents
    |> shown(last_actions)
    |> Enum.map(fn agent ->
      Map.merge(
        %{
          id: agent.id,
          name: agent.name,
          kind: to_string(agent.harness),
          # Patchbay's agents do not check in, so no row draws a light.
          light: nil,
          light_label: nil
        },
        last_line(last_actions[agent.id], now)
      )
    end)
  end

  defp last_line(%{site: site, at: at}, now),
    do: %{
      last_action: "Active on #{site}",
      last_action_iso: DateTime.to_iso8601(at),
      last_action_at: RegentFormat.short_relative_time(at, now)
    }

  defp last_line(:none, _now),
    do: %{last_action: "No activity yet", last_action_iso: nil, last_action_at: nil}

  defp last_line(nil, _now), do: %{last_action: nil, last_action_iso: nil, last_action_at: nil}

  @doc """
  The three agents the menu shows, from the person's agents newest paired first
  and where and when each was last active, by id (`:none` for one never active):
  the most recently active first, then the rest, keeping their order.
  """
  @spec shown([map()], %{optional(term()) => %{at: DateTime.t()} | :none}) :: [map()]
  def shown(agents, last_actions) do
    agents
    |> Enum.sort_by(&last_actions[&1.id], &more_recent?/2)
    |> Enum.take(3)
  end

  defp more_recent?(%{at: first}, %{at: second}), do: DateTime.compare(first, second) != :lt
  defp more_recent?(%{at: _first}, _never), do: true
  defp more_recent?(_never, %{at: _second}), do: false
  defp more_recent?(_never, _also_never), do: true

  # The kinds of failure alone: the failure's words can hold the person's id.
  defp failure_kinds(%{errors: [_ | _] = errors}), do: Enum.map(errors, & &1.__struct__)
  defp failure_kinds(error), do: [error.__struct__]
end
