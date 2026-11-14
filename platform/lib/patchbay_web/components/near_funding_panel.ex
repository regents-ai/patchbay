defmodule PatchbayWeb.NearFundingPanel do
  @moduledoc """
  Fund with NEAR on the Agents page (`Patchbay.NearFunding`), at patchbay.help
  only and only while it is switched on: the person picks one of their paired
  agents, an amount of USDC and the NEAR account any refund goes back to, and
  gets a price in NEAR and an address to send it to. The USDC goes to the
  agent's own wallet as Patchbay's record of the agent names it; the page
  never sends an address. Progress and the two transactions follow as the
  status job reads them: the parent watches the funding (`{:watch_near_funding,
  id}`) and passes each change in as `funding`.

  The parent passes `id`, `profile` and `lease` (`PatchbayWeb.CurrentProfile`).
  """
  use PatchbayWeb, :live_component

  alias Patchbay.NearFunding
  alias Patchbay.NearFunding.Funding
  alias PatchbayWeb.CurrentProfile
  alias Regent.Primitives, as: P
  alias RegentAgents.Person
  alias RegentPayments.USDC

  @no_price "A price couldn't be found just now. Try again in a moment."

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> CurrentProfile.check_component_lease(&take_profile/2)
     |> assign(errors: %{}, problem: nil, params: %{"amount_usdc" => "5.00", "refund_to" => ""})}
  end

  @impl true
  def update(%{funding: %Funding{} = funding}, socket) do
    if socket.assigns.funding && socket.assigns.funding.id == funding.id,
      do: {:ok, assign(socket, funding: funding)},
      else: {:ok, socket}
  end

  # The person's newest funding is read once, when the panel first shows.
  def update(%{id: id, profile: profile, lease: lease}, socket) do
    socket = socket |> assign(id: id, lease: lease) |> take_profile(profile) |> read_agents()

    if Map.has_key?(socket.assigns, :funding) do
      {:ok, socket}
    else
      funding = NearFunding.latest_funding!(actor: socket.assigns.person)
      if funding, do: send(self(), {:watch_near_funding, funding.id})
      {:ok, assign(socket, funding: funding)}
    end
  end

  defp take_profile(socket, profile),
    do: assign(socket, person: %Person{privy_user_id: profile.privy_user_id})

  defp read_agents(socket) do
    agents =
      case RegentAgents.list_my_agents(actor: socket.assigns.person) do
        {:ok, agents} -> agents
        {:error, _error} -> []
      end

    assign(socket, agents: agents)
  end

  @impl true
  def handle_event("fund", params, socket) do
    params = Map.take(params, ~w(agent_id amount_usdc refund_to))

    with {:ok, id} <- Ecto.UUID.cast(params["agent_id"]),
         {:ok, %{} = agent} <- RegentAgents.get_my_agent(id, actor: socket.assigns.person) do
      case NearFunding.start(socket.assigns.person, agent, params) do
        {:ok, funding} ->
          send(self(), {:watch_near_funding, funding.id})
          {:noreply, assign(socket, funding: funding, errors: %{}, problem: nil, params: params)}

        {:error, error} ->
          {:noreply, socket |> assign(params: params) |> refused(error)}
      end
    else
      _not_mine ->
        {:noreply,
         assign(socket, params: params, errors: %{}, problem: "Choose one of your agents.")}
    end
  end

  def handle_event("again", _params, socket),
    do: {:noreply, assign(socket, funding: nil, errors: %{}, problem: nil)}

  # A wrong amount or refund account is shown under its field; anything else,
  # such as a quote the service would not give, under the form.
  defp refused(socket, %Ash.Error.Invalid{errors: errors}) do
    fields = Enum.map(errors, &Map.get(&1, :field))

    errors = %{
      amount:
        if(:usdc_amount in fields, do: ["Enter an amount from 0.01 to 1000, such as 5.00."]),
      refund: if(:refund_to in fields, do: ["Enter a NEAR account, such as alice.near."])
    }

    assign(socket,
      errors: errors,
      problem: if(errors.amount || errors.refund, do: nil, else: @no_price)
    )
  end

  defp refused(socket, _error), do: assign(socket, errors: %{}, problem: @no_price)

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="rg-account pb-near-funding" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>Funding</h2>
      <p class="rg-account__status">
        Top up an agent's own USDC wallet on Base with NEAR. Send NEAR from your own wallet. Patchbay never holds your funds.
      </p>

      <p :if={@agents == [] and is_nil(@funding)} class="rg-account__empty">
        Pair an agent first.
      </p>

      <form
        :if={@agents != [] and is_nil(@funding)}
        id={"#{@id}-form"}
        class="pb-near-funding__form"
        phx-submit="fund"
        phx-target={@myself}
      >
        <P.field id={"#{@id}-agent"} label="Agent">
          <select id={"#{@id}-agent"} name="agent_id">
            <option
              :for={agent <- @agents}
              value={agent.id}
              selected={@params["agent_id"] == agent.id}
            >
              {agent.name}
            </option>
          </select>
        </P.field>
        <P.field id={"#{@id}-amount"} label="Amount (USDC)" errors={@errors[:amount] || []}>
          <input
            id={"#{@id}-amount"}
            name="amount_usdc"
            type="text"
            inputmode="decimal"
            autocomplete="off"
            value={@params["amount_usdc"]}
            required
          />
        </P.field>
        <P.field id={"#{@id}-refund"} label="Refund account" errors={@errors[:refund] || []}>
          <:hint>
            Your NEAR account, such as alice.near. NEAR comes back here if the swap can't finish.
          </:hint>
          <input
            id={"#{@id}-refund"}
            name="refund_to"
            type="text"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            placeholder="alice.near"
            value={@params["refund_to"]}
            required
          />
        </P.field>
        <P.notice :if={@problem} tone="error">{@problem}</P.notice>
        <div>
          <P.button type="submit" variant="primary">Fund with NEAR</P.button>
        </div>
      </form>

      <div :if={@funding} id={"#{@id}-funding"} class="pb-near-funding__funding">
        <dl class="pb-near-funding__facts">
          <div>
            <dt>Status</dt>
            <dd id={"#{@id}-status"} role="status">
              <P.status tone={tone(state(@funding))}>{state_words(state(@funding))}</P.status>
            </dd>
          </div>
          <div>
            <dt>Amount</dt>
            <dd>{USDC.format(@funding.usdc_amount)} USDC</dd>
          </div>
          <div>
            <dt>Price</dt>
            <dd id={"#{@id}-price"}>{near(@funding.near_amount)} NEAR</dd>
          </div>
          <div>
            <dt>Time</dt>
            <dd>About {@funding.time_estimate_s} seconds once your NEAR arrives</dd>
          </div>
          <div>
            <dt>Send to</dt>
            <dd>
              <P.address
                id={"#{@id}-deposit"}
                address={@funding.deposit_address}
                label={@funding.deposit_address}
                kind="id"
                variant="full"
              />
            </dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd>
              <P.address id={"#{@id}-wallet"} address={@funding.recipient} />
            </dd>
          </div>
          <div>
            <dt>Refund</dt>
            <dd>{@funding.refund_to}</dd>
          </div>
          <div :if={@funding.origin_tx}>
            <dt>NEAR sent</dt>
            <dd>
              <a
                id={"#{@id}-origin-tx"}
                href={"https://nearblocks.io/txns/#{@funding.origin_tx}"}
                target="_blank"
                rel="noopener noreferrer"
              >
                View on NearBlocks
              </a>
            </dd>
          </div>
          <div :if={@funding.destination_tx}>
            <dt>USDC arrived</dt>
            <dd>
              <P.address id={"#{@id}-destination-tx"} address={@funding.destination_tx} kind="tx" />
            </dd>
          </div>
        </dl>
        <p :if={state(@funding) == :pending_deposit} class="rg-account__status">
          Send {near(@funding.near_amount)} NEAR to the address above before {Calendar.strftime(
            @funding.deadline,
            "%H:%M UTC"
          )}. The USDC goes to your agent's own wallet, shown above, and your agent pays from it as usual.
        </p>
        <div>
          <P.button type="button" variant="secondary" phx-click="again" phx-target={@myself}>
            Fund again
          </P.button>
        </div>
      </div>
    </section>
    """
  end

  # A deposit address that closed before any NEAR reached it reads as expired.
  defp state(%{state: :pending_deposit, deadline: deadline}) do
    if DateTime.after?(DateTime.utc_now(), deadline), do: :expired, else: :pending_deposit
  end

  defp state(%{state: state}), do: state

  defp state_words(:pending_deposit), do: "Waiting"
  defp state_words(:expired), do: "Expired"
  defp state_words(:processing), do: "Processing"
  defp state_words(:success), do: "Arrived"
  defp state_words(:refunded), do: "Refunded"
  defp state_words(:failed), do: "Failed"

  defp tone(:success), do: "success"
  defp tone(:failed), do: "error"
  defp tone(state) when state in [:refunded, :expired], do: "warning"
  defp tone(_waiting), do: "info"

  # The quote's NEAR amount rounded up to six places, as a person types it in
  # a wallet: never less than the quote asks for.
  defp near(amount),
    do: amount |> Decimal.new() |> Decimal.round(6, :ceiling) |> Decimal.to_string(:normal)
end
