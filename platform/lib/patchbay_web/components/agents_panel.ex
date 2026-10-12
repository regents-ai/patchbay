defmodule PatchbayWeb.AgentsPanel do
  @moduledoc """
  The agents a person has paired with their account (`RegentAgents`), a code to
  pair another, and Unpair for each, as in the Regent template.

  Pairing lets an agent act for the person on Patchbay, each thing it does
  marked as its own. It never touches their wallet. Pairing is shared by every
  Regent site, so an agent paired on another one is listed here too.

  The parent passes `profile` (signed in with Privy), the page's
  `profile_claim` and `id`, and sends `agents_changed: true` when an agent
  pairs, checks in or is unpaired anywhere.
  """
  use PatchbayWeb, :live_component

  alias PatchbayWeb.CurrentProfile
  alias Regent.Primitives, as: P
  alias RegentAgents.{Harness, PairingCode, Person}

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> CurrentProfile.check_component_events(&take_profile/2)
       |> assign(pairing: nil, notice: nil)}

  @impl true
  def update(%{agents_changed: true}, socket), do: {:ok, read_agents(socket)}

  def update(%{profile: profile, id: id, profile_claim: claim}, socket) do
    {:ok,
     socket
     |> assign(id: id, profile_claim: claim)
     |> take_profile(profile)
     |> read_agents()}
  end

  # The profile as the page gave it, or as it reads now before each event and
  # each background result (`CurrentProfile.check_component_events/2`).
  defp take_profile(socket, profile),
    do: assign(socket, person: %Person{privy_user_id: profile.privy_user_id})

  @impl true
  def handle_event("issue_pairing_code", _params, socket),
    do: {:noreply, assign(socket, pairing: issue(socket), notice: nil)}

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
      <Regent.Account.agents id={"#{@id}-list"} agents={rows(@agents)} notice={@notice}>
        <:about>
          Pairing lets an agent post and answer on Patchbay for you.
          Each thing it does is marked as its own. It can never use your wallet.
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
          >
            Unpair
          </P.button>
        </:actions>
        <:footer>
          <P.button
            id={"#{@id}-pair"}
            type="button"
            variant="secondary"
            phx-click="issue_pairing_code"
            phx-target={@myself}
            phx-disable-with="Making a code…"
          >
            {if match?(%PairingCode.Issued{}, @pairing), do: "Make a new code", else: "Pair an agent"}
          </P.button>
          <.pairing id={@id} pairing={@pairing} />
        </:footer>
      </Regent.Account.agents>
    </div>
    """
  end

  defp rows(:unavailable), do: :unavailable

  defp rows(agents) do
    now = DateTime.utc_now()

    Enum.map(
      agents,
      &%{
        id: &1.id,
        name: &1.name,
        harness: Harness.label(&1.harness),
        backed: not is_nil(&1.human_id),
        last_contact_iso: DateTime.to_iso8601(&1.last_contact_at),
        last_contact: RegentFormat.relative_time(&1.last_contact_at, now)
      }
    )
  end

  attr :id, :string, required: true
  attr :pairing, :any, required: true

  defp pairing(%{pairing: nil} = assigns), do: ~H""

  defp pairing(%{pairing: %PairingCode.Issued{}} = assigns) do
    assigns =
      assign(assigns,
        expires_iso: DateTime.to_iso8601(assigns.pairing.expires_at),
        expires: Calendar.strftime(assigns.pairing.expires_at, "%H:%M UTC")
      )

    ~H"""
    <div id={"#{@id}-code"} class="pb-account-agents__code" role="status">
      <p>
        Enter this code when your agent asks for it, never in a chat.
        Works once, until <time datetime={@expires_iso}>{@expires}</time>.
        <a href="/agents.md">How to pair</a>
      </p>
      <pre><code>{@pairing.code}</code></pre>
      <P.copy_button id={"#{@id}-copy"} text={@pairing.code} variant="primary">Copy</P.copy_button>
    </div>
    """
  end

  defp pairing(%{pairing: {:paired, agent}} = assigns) do
    assigns = assign(assigns, :agent, agent)

    ~H"""
    <p id={"#{@id}-code"} role="status">{@agent.name} paired with your account.</p>
    """
  end

  defp pairing(%{pairing: :wait} = assigns) do
    ~H"""
    <p id={"#{@id}-code"} role="status">A new code can be made once a minute. Try again shortly.</p>
    """
  end

  defp pairing(assigns) do
    ~H"""
    <p id={"#{@id}-code"} role="status">A code couldn’t be made right now. Try again.</p>
    """
  end

  defp read_agents(socket) do
    agents =
      case RegentAgents.list_my_agents(actor: socket.assigns.person) do
        {:ok, agents} -> agents
        {:error, _error} -> :unavailable
      end

    assign(socket, agents: agents, pairing: after_pairing(socket.assigns.pairing, agents))
  end

  # A code on screen gives way to the agent that used it, so a spent code is
  # never left there to send again.
  defp after_pairing(%PairingCode.Issued{issued_at: issued_at} = shown, agents)
       when is_list(agents) do
    case Enum.find(agents, &(DateTime.compare(&1.paired_at, issued_at) != :lt)) do
      nil -> shown
      agent -> {:paired, agent}
    end
  end

  defp after_pairing(shown, _agents), do: shown

  # A code already on screen stays there while a new one can't be made yet.
  defp issue(socket) do
    case RegentAgents.issue_pairing_code(actor: socket.assigns.person) do
      {:ok, issued} ->
        issued

      {:error,
       %Ash.Error.Invalid{errors: [%Ash.Error.Invalid.Unavailable{reason: :issued_recently}]}} ->
        if match?(%PairingCode.Issued{}, socket.assigns.pairing),
          do: socket.assigns.pairing,
          else: :wait

      {:error, _error} ->
        :unavailable
    end
  end
end
