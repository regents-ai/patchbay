defmodule PatchbayWeb.PointsLive do
  @moduledoc """
  The signed-in person's Regent Points, as in the Regent template: the total
  with today and yesterday, the actions left, the leaderboard, the NFT bonus
  added at the end of each 30-day period, and the activity. The pieces are
  `Regent.Points`; this page supplies their words. Nothing earns until earning
  opens.

  The page reads the person's shared Regent account
  (`Patchbay.Accounts.HumanAccount`), which their sign-in recorded, and the
  board every signed-in reader shares (`Patchbay.Points.Board`). Like
  `/account`, it stays in place and says so when the sign-in ends while open.
  """

  use PatchbayWeb, :live_view

  alias Patchbay.Points.Board
  alias Patchbay.SharedReading
  alias PatchbayWeb.{PointsEntries, Read}
  alias RegentPoints.{Amount, Rules}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(PatchbayWeb.PublicDocuments.page("/points"))
      |> assign(
        points: %Read{},
        board: %Read{},
        bonus: %Read{},
        earning: Rules.active(),
        person: nil,
        rolls?: false
      )

    case socket.assigns.current_profile do
      nil ->
        {:ok, socket}

      profile ->
        {:ok,
         socket
         |> person(profile)
         |> subscribe()
         |> read_points()
         |> read_board()
         |> read_bonus()}
    end
  end

  # A points award or correction for this account, and the shared board read
  # again; the page follows both. The total rolls only for an award that lands
  # after this connection's first render, so a total that changed while the
  # page was away is simply there when it connects again.
  defp subscribe(%{assigns: %{person: %{human_account_id: id}}} = socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, "points:#{id}")
      :ok = SharedReading.subscribe(Board.key())
      send(self(), :rolls)
    end

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

  def handle_info({:shared_reading, {:points_board, _program}}, socket),
    do: {:noreply, read_board(socket)}

  def handle_info(:rolls, socket), do: {:noreply, assign(socket, rolls?: true)}

  @impl true
  def handle_async({Read, _name, _generation} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  # Read during the render, so the total and the actions left are on the page
  # from its first paint.
  defp read_points(%{assigns: %{person: %{} = person}} = socket) do
    Read.now(socket, :points, person.human_account_id, fn ->
      RegentPoints.summary(actor: person)
    end)
  end

  defp read_points(socket), do: socket

  defp read_board(%{assigns: %{person: %{}}} = socket),
    do: assign(socket, :board, board_read(SharedReading.fetch(Board.key())))

  defp read_board(socket), do: socket

  # Loading until the board is first read, an error when that first read failed,
  # and behind when a later read failed.
  defp board_read(:error), do: %Read{state: :loading}
  defp board_read({:ok, %{reading: nil}}), do: %Read{state: :error, error: :not_read}

  defp board_read({:ok, %{reading: board, at: at, degraded?: true}}),
    do: %Read{state: :stale, value: board, read_at: at, error: :not_read}

  defp board_read({:ok, %{reading: board, at: at}}),
    do: %Read{state: :ready, value: board, read_at: at}

  # The NFT tier is read from Base once per page open, never on each award
  # notice, against the wallet-read allowance (`Patchbay.Limits`). While earning
  # is off there is no period to add a bonus to, so nothing is read.
  defp read_bonus(%{assigns: %{earning: []}} = socket), do: socket

  defp read_bonus(%{assigns: %{person: %{human_account_id: id}}} = socket) do
    profile_id = socket.assigns.current_profile.id

    Read.start(socket, :bonus, id, fn ->
      case Patchbay.Limits.spend(:wallet_read, {:profile, profile_id}) do
        :ok -> RegentPoints.Bonus.current(id)
        :limited -> {:error, :limited}
      end
    end)
  end

  defp read_bonus(socket), do: socket

  @impl true
  def render(assigns) do
    open? = assigns.earning != []
    summary = assigns.points.value
    groups = if summary, do: PointsEntries.todo(summary, open?), else: []

    places =
      assigns.person && assigns.board.value &&
        PointsEntries.board(
          assigns.board.value,
          assigns.person.human_account_id,
          summary && summary.balance_micro
        )

    assigns =
      assign(assigns,
        open?: open?,
        summary: summary,
        groups: Enum.map(groups, &linked/1),
        left: if(summary && open?, do: PointsEntries.left(groups)),
        places: places,
        rows: if(summary, do: Enum.map(summary.entries, &row(&1, summary.agent_names)), else: [])
      )

    ~H"""
    <main id="points-page" class="patchbay-shell pb-account-page">
      <header class="pb-account-heading">
        <h1 tabindex="-1">Points</h1>
      </header>

      <PatchbayWeb.AccountLive.tabs current={:points} site_edition={@site_edition} />

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

      <Regent.Points.layout :if={@current_profile && (@person || @points.state == :error)}>
        <:total>
          <%!-- The total's figure rolls when an award lands while the page is open.
            The count is set only once there is a total, so a figure that arrives
            after "–" is simply there, and only after this connection's first
            render (`subscribe/1`). --%>
          <div
            id="points-total-frame"
            class="pb-points-total"
            phx-hook={@rolls? && @summary && "MotionCount"}
            data-variant={PatchbayWeb.Motion.standard("count")}
          >
            <Regent.Points.total
              id="points-total"
              total={@summary && Amount.format(@summary.balance_micro)}
              today={@summary && Amount.format(@summary.earned_today_micro)}
              yesterday={@summary && Amount.format(@summary.earned_yesterday_micro)}
              rank={@places && @places.rank && to_string(@places.rank)}
              pending={if @summary, do: @summary.pending, else: 0}
              state={state(@points)}
            >
              A record of everything you and your agents do across Regents. One total, on every site.
            </Regent.Points.total>
          </div>
        </:total>
        <:main>
          <Regent.Points.todo :if={@summary} id="points-todo" left={@left} groups={@groups}>
            <p :if={!@open?} role="status">Earning hasn’t opened yet.</p>
          </Regent.Points.todo>
          <Regent.Points.activity
            :if={@summary}
            id="points-activity"
            rows={@rows}
            more={@summary.more?}
          >
            <:tip :let={row}>
              <Regent.Primitives.tip id={"points-limit-#{row.id}"} label="About this award’s limit">
                {row.note}
              </Regent.Primitives.tip>
            </:tip>
          </Regent.Points.activity>
        </:main>
        <:side>
          <Regent.Points.board
            id="points-board"
            rows={if @places, do: @places.rows, else: []}
            you={@places && @places.you}
            state={state(@board)}
          >
            <:face :let={row}>
              <img
                :if={row.picture}
                class="pb-av pb-av-picture pb-points-face"
                src={row.picture}
                referrerpolicy="no-referrer"
                alt=""
              />
              <PatchbayWeb.Forum.Avatar.avatar
                :if={!row.picture}
                kind={:human}
                seed={row.wallet || row.line}
                class="pb-points-face"
              />
            </:face>
          </Regent.Points.board>
          <Regent.Points.bonus
            id="points-bonus"
            state={bonus_state(@open?, @bonus)}
            nfts={@bonus.value && @bonus.value.nft_count}
            percent={@bonus.value && @bonus.value.percent}
            message={"Your NFTs could not be checked. #{retry(@bonus.error)}"}
            tiers={tiers(@bonus.value)}
            periods={if @summary, do: periods(@summary), else: []}
          >
            <:tip>
              <Regent.Primitives.tip id="points-bonus-about" label="About your points bonus">
                Animata I, Animata II and Regents Club count across your verified linked wallets.
                At the end of each 30-day period, the tier your wallets hold that day adds its
                bonus to the points you earned in that period, one-time awards included.
              </Regent.Primitives.tip>
            </:tip>
          </Regent.Points.bonus>
        </:side>
      </Regent.Points.layout>
    </main>
    """
  end

  # The page where each action is done, for the ones this site has a page for.
  @links %{"agent.activated" => "/account/agents"}

  defp linked(group) do
    items =
      Enum.map(group.items, fn item ->
        item
        |> Map.put(:points, item.points && "+" <> item.points)
        |> then(&if href = @links[item.id], do: Map.put(&1, :href, href), else: &1)
      end)

    %{group | items: items}
  end

  defp row(entry, agent_names) do
    status = PointsEntries.status(entry)

    %{
      id: entry.id,
      label: Rules.label(entry.rule_id),
      by: PointsEntries.agent_name(entry, agent_names) || "You",
      at: Calendar.strftime(entry.earned_at, "%-d %b, %H:%M UTC"),
      points: signed(entry.points_micro_delta),
      status: if(status != :counted, do: PointsEntries.status_label(status)),
      note: if(entry.cap_reduction_micro > 0, do: cut(entry))
    }
  end

  defp cut(entry) do
    "#{Amount.format(entry.points_micro_delta + entry.cap_reduction_micro)} before limits, " <>
      "#{Amount.format(entry.points_micro_delta)} awarded. The rest was over the daily limit."
  end

  defp signed(micro) when micro < 0, do: "−" <> Amount.format(-micro)
  defp signed(micro), do: "+" <> Amount.format(micro)

  # The period running now, then the bonuses already added, newest first.
  defp periods(summary) do
    current =
      case summary.current_period do
        %{number: number, ends_at: ends_at, earned_micro: earned} ->
          [
            %{
              label: "Period #{number}",
              value:
                "#{Amount.format(earned)} earned, ends #{Calendar.strftime(ends_at, "%-d %b")}"
            }
          ]

        nil ->
          []
      end

    current ++
      Enum.map(summary.period_bonuses, fn period ->
        %{
          label: "Period #{period.period}",
          value:
            "+#{Amount.format(period.bonus_micro)} (#{period.nft_count} NFTs, +#{period.bonus_percent}%)"
        }
      end)
  end

  # Ascending tiers, each running up to the next one's minimum.
  defp tiers(held) do
    ascending = Enum.sort(RegentPoints.Bonus.tiers())
    next = Enum.map(Enum.drop(ascending, 1), &elem(&1, 0)) ++ [nil]
    count = held && held.nft_count

    Enum.zip_with(ascending, next, fn
      {minimum, percent}, nil ->
        %{range: "#{minimum}+", percent: percent, held: is_integer(count) and count >= minimum}

      {minimum, percent}, upper ->
        %{
          range: "#{minimum}–#{upper - 1}",
          percent: percent,
          held: is_integer(count) and count in minimum..(upper - 1)
        }
    end)
  end

  defp state(%{state: state}) when state in [:idle, :loading], do: :loading
  defp state(%{state: state}) when state in [:ready, :empty], do: :ready
  defp state(%{state: state}), do: state

  defp bonus_state(false, _bonus), do: :closed
  defp bonus_state(true, bonus), do: state(bonus)

  # Reading again at once while limited would only be refused again.
  defp retry(:limited), do: "Try again in a minute."
  defp retry(_reason), do: "Try refreshing this page."
end
