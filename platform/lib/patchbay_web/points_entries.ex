defmodule PatchbayWeb.PointsEntries do
  @moduledoc """
  How the Points page and the agent's Points answer describe one account's
  Points (`RegentPoints.summary/1` and the board every reader shares,
  `Patchbay.Points.Board`), so both say the same thing about each action,
  entry and place.
  """

  alias RegentPoints.{Amount, Rules}

  @doc "What became of an entry: counted, cut to nothing by a daily limit, or a correction."
  def status(%{reversal_of_entry_id: id}) when not is_nil(id), do: :correction
  def status(%{points_micro_delta: 0}), do: :allowance_reached
  def status(_entry), do: :counted

  def status_label(:counted), do: "Counted"
  def status_label(:allowance_reached), do: "Limit reached"
  def status_label(:correction), do: "Correction"

  @doc "Who earned an entry, by the name the person gave their agent."
  def agent_name(%{actor_kind: "agent", actor_id: id}, names),
    do: Map.get(names, id, "Previously connected agent")

  def agent_name(_entry, _names), do: nil

  @doc """
  Every action a Points page lists (`RegentPoints.Rules.groups/0`), under the
  site it belongs to, whichever site earns it: `[%{title, items}]`, `title` the
  site's name. An action is done once the account has it on any site, ever for
  a one-time action and today for a daily one; `here` is whether this site earns
  it. `open?` is false until earning opens here: until then an action carries no
  points and nothing is left. Once it opens, an action this site does not earn
  says so, and a daily one it earns shows today's count.
  """
  def todo(summary, open?) do
    room = daily_room(summary)

    for %{site: site, rules: rules} <- Rules.groups() do
      %{
        title: site,
        items: Enum.map(rules, &item(&1, Map.fetch!(summary.done, &1["id"]), room, open?))
      }
    end
  end

  @doc """
  The one limit every daily action shares, whoever acted and on whichever site:
  `%{label, used, of, value}`, or nil while no daily action earns here.
  """
  def daily_limit(summary) do
    case daily_room(summary) do
      nil ->
        nil

      %{limit: limit, remaining: remaining} ->
        used = whole(limit - remaining)

        %{
          label: "Daily limit",
          used: used,
          of: whole(limit),
          value: "#{used} of #{whole(limit)} today"
        }
    end
  end

  defp daily_room(summary), do: Enum.find(summary.allowances, &(&1.scope == "activity:account"))

  @doc "How many listed actions can still earn: today for a daily one."
  def left(groups), do: groups |> Enum.flat_map(& &1.items) |> Enum.count(& &1.left)

  @doc """
  The shared board for one reader: `%{rows, you, rank}`. `reader` is the reader's
  account id and `summary` their own summary (`RegentPoints.summary/1`), or `nil`
  while it is not read. `you` is the reader's row when they sit below the listed
  rows, with the place and total from their summary; `rank` is their place
  wherever they sit. The rows' account ids stay here: none reaches a page or an
  agent. A row's `name` is `nil` when the person shows by their `wallet`, under
  its `ens_name` when it has one. A row's `line` is its position in the list:
  names and places repeat, lines do not.
  """
  def board(%{top: top}, reader, summary) do
    own = Enum.find(top, &(&1.account_id == reader))
    you = below(own, summary)

    %{
      rows:
        top
        |> Enum.with_index(1)
        |> Enum.map(fn {row, line} ->
          %{
            line: line,
            rank: row.rank,
            name: row.name,
            wallet: row.wallet,
            ens_name: row.ens_name,
            squares: row.squares,
            picture: row.picture,
            points: Amount.format(row.points_micro),
            you: row.account_id == reader
          }
        end),
      you: you,
      rank: if(own, do: own.rank, else: you && you.rank)
    }
  end

  # The reader's own row under the listed ones, while they have a place.
  defp below(nil, %{place: place, balance_micro: total}) when is_integer(place),
    do: %{rank: place, points: Amount.format(total)}

  defp below(_own, _summary), do: nil

  @doc "The agent's Points answer: the same figures the Points page shows."
  def answer(summary, board, reader, open?) do
    board = board(board, reader, summary)

    %{
      points: Amount.format(summary.balance_micro),
      earned_today: Amount.format(summary.earned_today_micro),
      earned_yesterday: Amount.format(summary.earned_yesterday_micro),
      rank: board.rank,
      activity_being_verified: summary.pending,
      to_do:
        for group <- todo(summary, open?), item <- group.items do
          %{
            site: group.title,
            label: item.label,
            repeats: item.repeats,
            points: item.points,
            done: item.done,
            left: item.left,
            earns_here: item.here,
            today: item[:count]
          }
        end,
      daily_limits:
        Enum.map(
          summary.allowances,
          &%{
            name: limit_name(&1.scope),
            limit: Amount.format(&1.limit),
            remaining: Amount.format(&1.remaining)
          }
        ),
      leaderboard:
        Enum.map(board.rows, &Map.take(&1, [:rank, :name, :wallet, :ens_name, :points, :you])),
      entries:
        Enum.map(summary.entries, fn entry ->
          %{
            label: Rules.label(entry.rule_id),
            points: Amount.format(entry.points_micro_delta),
            status: status(entry),
            allowance_reduction: Amount.format(entry.cap_reduction_micro),
            by: if(entry.actor_kind == "agent", do: "agent", else: "person"),
            agent: agent_name(entry, summary.agent_names),
            earned_at: entry.earned_at
          }
        end),
      period_bonuses:
        Enum.map(
          summary.period_bonuses,
          &%{
            period: &1.period,
            points: Amount.format(&1.bonus_micro),
            nft_count: &1.nft_count,
            bonus_percent: &1.bonus_percent
          }
        ),
      more: summary.more?
    }
  end

  defp limit_name("activity:account"), do: "Daily actions, you and your agents"

  defp item(%{"category" => "milestone"} = rule, %{times: times, here: here}, _room, open?) do
    done = times >= 1

    rule
    |> base("once", here, open?)
    |> Map.merge(%{done: done, left: open? and not done})
    |> note(rule, times, open?)
  end

  # A daily action stays to do until today's count is used, unless the daily limit
  # is spent.
  defp item(
         %{"category" => "activity", "count" => of} = rule,
         %{times: times, here: here},
         room,
         open?
       )
       when is_integer(of) do
    rule
    |> base("daily", here, open?)
    |> Map.merge(%{
      done: times >= of,
      left: open? and times < of and not match?(%{remaining: 0}, room)
    })
    |> note(rule, times, open?)
  end

  defp base(%{"id" => id, "points" => points}, repeats, here, open?) do
    %{
      id: id,
      label: Rules.label(id),
      repeats: repeats,
      points: if(open?, do: to_string(points)),
      here: here
    }
  end

  # Once earning opens here: an action this site does not earn says so, and a
  # daily one it earns shows today's count against its daily count.
  defp note(item, _rule, _times, false), do: item

  defp note(%{here: false} = item, _rule, _times, true),
    do: Map.put(item, :note, "Not on this site")

  defp note(item, %{"category" => "activity", "count" => of}, times, true) do
    item
    |> Map.put(:note, "#{times} of #{of} today")
    |> then(&if of > 1, do: Map.put(&1, :count, %{done: times, of: of}), else: &1)
  end

  defp note(item, _once, _times, true), do: item

  defp whole(micro), do: div(micro, Rules.unit())
end
