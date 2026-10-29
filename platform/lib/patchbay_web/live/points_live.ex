defmodule PatchbayWeb.PointsLive do
  @moduledoc """
  The signed-in person's Regent Points, as in the Regent template: what they
  and their paired agents have earned, counted in one account shared by every
  Regent site, their NFT bonus once earning opens, and what earns points. The
  NFT bonus is added at the end of each 30-day period. Nothing earns until
  earning opens.

  The page reads the person's shared Regent account
  (`Patchbay.Accounts.HumanAccount`), which their sign-in recorded. Like
  `/account`, it stays in place and says so when the sign-in ends while open.
  """

  use PatchbayWeb, :live_view

  alias PatchbayWeb.{CreditsLimit, Read}
  alias RegentPoints.{Amount, Rules}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(PatchbayWeb.PublicDocuments.page("/points"))
      |> assign(
        points: %Read{},
        bonus: %Read{},
        earning: Rules.active(),
        person: nil
      )

    case socket.assigns.current_profile do
      nil ->
        {:ok, socket}

      profile ->
        {:ok, socket |> person(profile) |> subscribe() |> read_points() |> read_bonus()}
    end
  end

  # A points award or correction for this account; the page reads again.
  defp subscribe(%{assigns: %{person: %{human_account_id: id}}} = socket) do
    if connected?(socket), do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, "points:#{id}")
    socket
  end

  defp subscribe(socket), do: socket

  # A failed account lookup shows the page's "could not be read" notice.
  defp person(socket, %{privy_user_id: did}) do
    case Patchbay.Accounts.by_privy(did, actor: %{role: :system}) do
      {:ok, %{id: id}} -> assign(socket, person: %{role: :human, human_account_id: id})
      {:ok, nil} -> socket
      {:error, error} -> assign(socket, points: %Read{state: :error, error: error})
    end
  end

  @impl true
  def handle_info(%{topic: "points:" <> _}, socket), do: {:noreply, read_points(socket)}

  @impl true
  def handle_async({Read, _name, _generation} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  defp read_points(%{assigns: %{person: %{} = person}} = socket) do
    Read.start(socket, :points, person.human_account_id, fn ->
      RegentPoints.summary(actor: person)
    end)
  end

  defp read_points(socket), do: socket

  # The NFT tier is read from Base once per page open, never on each award
  # notice, against the same allowance as the Buy panel's reads. While earning
  # is off there is no period to add a bonus to, so nothing is read.
  defp read_bonus(%{assigns: %{earning: []}} = socket), do: socket

  defp read_bonus(%{assigns: %{person: %{human_account_id: id}}} = socket) do
    profile_id = socket.assigns.current_profile.id

    Read.start(socket, :bonus, id, fn ->
      case CreditsLimit.spend(:wallet_read, profile_id) do
        :ok -> RegentPoints.Bonus.current(id)
        :limited -> {:error, :limited}
      end
    end)
  end

  defp read_bonus(socket), do: socket

  @impl true
  def render(assigns) do
    tracked = Rules.tracked()
    assigns = assign(assigns, daily: daily(tracked), once: once(tracked), apps: apps(tracked))

    ~H"""
    <main id="points-page" class="patchbay-shell pb-account-page">
      <header class="pb-account-heading">
        <h1 tabindex="-1">Points</h1>
        <p>What you and your paired agents earn on Regent sites, counted in one account.</p>
      </header>

      <PatchbayWeb.AccountLive.tabs current={:points} />

      <Regent.Account.signed_out
        :if={is_nil(@current_profile)}
        id="points-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button variant="primary" type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>

      <p :if={@current_profile && is_nil(@person) && @points.state != :error} role="status">
        Your Points account opens the next time you sign in.
      </p>
      <p
        :if={
          @current_profile && @person && is_nil(@points.value) && @points.state in [:idle, :loading]
        }
        role="status"
      >
        Reading your points…
      </p>
      <Regent.Primitives.notice :if={@current_profile && @points.state == :error} tone="error">
        Points could not be read. Try refreshing this page.
      </Regent.Primitives.notice>

      <div
        :if={@current_profile && @points.value}
        id="points-sections"
        class="pb-account-grid"
        phx-hook="MotionCascade"
        data-variant={PatchbayWeb.Motion.standard("grid")}
      >
        <Regent.Account.points_summary
          id="account-points-summary"
          title="Balance"
          confirmed={Amount.format(@points.value.balance_micro)}
          today={Amount.format(@points.value.earned_today_micro)}
          pending={to_string(@points.value.pending)}
          state={summary_state(@points.state)}
          allowances={
            Enum.map(
              if(@earning == [], do: [], else: @points.value.allowances),
              &%{label: scope_name(&1.scope), value: "#{Amount.format(&1.remaining)} remaining"}
            )
          }
        />
        <section :if={@earning != []} id="points-bonus" class="pb-account-panel">
          <h2>
            Your bonus
            <Regent.Primitives.tip id="points-bonus-about" label="About your points bonus">
              Animata I, Animata II and Regents Club count across your verified linked wallets.
              At the end of each 30-day period, the tier your wallets hold that day adds its
              bonus to the points you earned in that period, one-time awards included.
            </Regent.Primitives.tip>
          </h2>
          <p :if={@bonus.state in [:idle, :loading]} role="status">Checking your NFTs…</p>
          <p :if={@bonus.state in [:error, :stale] and @bonus.error == :limited}>
            Your NFTs could not be checked just now. Try again in a minute.
          </p>
          <p :if={@bonus.state in [:error, :stale] and @bonus.error != :limited}>
            Your NFTs could not be checked. Try refreshing this page.
          </p>
          <dl :if={@bonus.state == :ready} class="pb-points-figures">
            <div>
              <dt>NFTs held</dt>
              <dd>{@bonus.value.nft_count}</dd>
            </div>
            <div>
              <dt>Bonus this period</dt>
              <dd>+{@bonus.value.percent}%</dd>
            </div>
          </dl>
          <dl :if={@points.value.period_bonuses != []} class="pb-points-figures">
            <div :for={period <- @points.value.period_bonuses}>
              <dt>Period {period.period}</dt>
              <dd>
                +{Amount.format(period.bonus_micro)} ({period.nft_count} NFTs, +{period.bonus_percent}%)
              </dd>
            </div>
          </dl>
        </section>
        <section class="pb-account-panel">
          <h2>Activity</h2>
          <p :if={@points.value.entries == []}>No confirmed points activity yet.</p>
          <ol class="pb-points-activity">
            <li :for={entry <- @points.value.entries}>
              <p>
                {Rules.label(entry.rule_id)} · {actor_name(entry, @points.value.agent_names)}
              </p>
              <p>{Amount.format(entry.points_micro_delta)} points</p>
              <Regent.Primitives.tip
                :if={entry.cap_reduction_micro > 0}
                id={"points-cap-#{entry.id}"}
                label="About this award’s allowance"
              >
                {Amount.format(entry.points_micro_delta + entry.cap_reduction_micro)} before limits; {Amount.format(
                  entry.points_micro_delta
                )} awarded. {Amount.format(entry.cap_reduction_micro)} exceeded the daily or per-action allowance.
              </Regent.Primitives.tip>
              <p>
                {entry_status(entry)} · {Calendar.strftime(entry.earned_at, "%d %b %Y %H:%M UTC")}
              </p>
            </li>
          </ol>
          <p :if={@points.value.more?}>Showing the latest 50 entries.</p>
        </section>
      </div>

      <section id="points-earn" class="pb-account-panel">
        <h2>Earning</h2>
        <p :if={@earning == []} role="status">Earning hasn’t opened yet.</p>
        <h3 :if={@daily != []}>Every day</h3>
        <.ways :if={@earning == []} rules={@daily} />
        <table :if={@earning != [] and @daily != []} class="pb-points-table">
          <thead>
            <tr>
              <th scope="col">Action</th><th scope="col">Points</th><th scope="col">Limit</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @daily}>
              <th scope="row">
                {Rules.label(rule["id"])}<.not_yet rule={rule} earning={@earning} />
              </th>
              <td>{points(rule)}</td>
              <td>{limit(rule)}</td>
            </tr>
          </tbody>
        </table>
        <h3 :if={@once != []}>Once</h3>
        <.ways :if={@earning == []} rules={@once} />
        <table :if={@earning != [] and @once != []} class="pb-points-table">
          <thead>
            <tr>
              <th scope="col">Action</th><th scope="col">Points</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @once}>
              <th scope="row">
                {Rules.label(rule["id"])}<.not_yet rule={rule} earning={@earning} />
              </th>
              <td>{points(rule)}</td>
            </tr>
          </tbody>
        </table>
        <div :if={@earning != [] and @apps != []}>
          <h3>Daily limits</h3>
          <dl class="pb-points-figures">
            <div>
              <dt>You and your agents</dt>
              <dd>Up to {whole(Rules.daily_cap("activity:account"))} a day on {names(@apps)}</dd>
            </div>
          </dl>
        </div>
        <p :if={@earning != []}>
          Each day starts at midnight UTC, when Earned today and the daily limits start over.
        </p>
        <h3>NFT bonus</h3>
        <p>
          Animata I, Animata II and Regents Club in your linked wallets, counted at the end of each 30-day period. That period’s points get the bonus.
        </p>
        <table :if={@earning != []} class="pb-points-table">
          <thead>
            <tr>
              <th scope="col">NFTs</th><th scope="col">Bonus</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{nfts, percent} <- tiers()}>
              <th scope="row">{nfts}</th><td>+{percent}%</td>
            </tr>
          </tbody>
        </table>
      </section>
    </main>
    """
  end

  attr :rules, :list, required: true

  # Before earning opens, the ways to earn are named with no amounts.
  defp ways(assigns) do
    ~H"""
    <ul :if={@rules != []} class="pb-points-ways">
      <li :for={rule <- @rules}>{Rules.label(rule["id"])}</li>
    </ul>
    """
  end

  attr :rule, :map, required: true
  attr :earning, :list, required: true

  defp not_yet(assigns) do
    ~H"""
    <span :if={@rule not in @earning} class="pb-points-soon">Not yet</span>
    """
  end

  defp daily(rules), do: Enum.filter(rules, &(&1["category"] in ["credits", "activity"]))
  defp once(rules), do: Enum.filter(rules, &(&1["category"] == "milestone"))

  defp points(%{"category" => "credits", "micro_points_per_atomic_usdc" => rate}),
    do: "#{whole(rate * 1_000_000)} per USDC"

  defp points(%{"points" => points}), do: points

  defp limit(%{"category" => "credits", "daily_caps_micro" => caps}),
    do: "Up to #{whole(caps["credits"])} a day"

  defp limit(%{"count" => 1}), do: "Once a day"
  defp limit(%{"count" => 2}), do: "Twice a day"
  defp limit(%{"count" => count}), do: "#{count} times a day"

  defp whole(micro), do: div(micro, Rules.unit())

  defp apps(rules), do: rules |> Rules.daily_apps() |> Enum.map(&String.capitalize/1)

  defp names([name]), do: name

  defp names(names) do
    {last, rest} = List.pop_at(names, -1)
    Enum.join(rest, ", ") <> " and " <> last
  end

  # Ascending tiers, each running up to the next one's minimum.
  defp tiers do
    ascending = Enum.sort(RegentPoints.Bonus.tiers())
    next = Enum.map(Enum.drop(ascending, 1), &elem(&1, 0)) ++ [nil]

    Enum.zip_with(ascending, next, fn
      {minimum, percent}, nil -> {"#{minimum}+", percent}
      {minimum, percent}, upper -> {"#{minimum}–#{upper - 1}", percent}
    end)
  end

  defp actor_name(%{actor_kind: "human"}, _names), do: "You"
  defp actor_name(entry, names), do: Map.get(names, entry.actor_id, "Previously connected agent")

  defp entry_status(%{reversal_of_entry_id: id}) when not is_nil(id), do: "Correction"
  defp entry_status(%{points_micro_delta: 0}), do: "Allowance reached"
  defp entry_status(_), do: "Confirmed"

  defp summary_state(state) when state in [:idle, :loading], do: :loading
  defp summary_state(:empty), do: :ready
  defp summary_state(state), do: state

  defp scope_name("activity:account"), do: "You and your agents"
  defp scope_name("credits"), do: "Credits purchases"
end
