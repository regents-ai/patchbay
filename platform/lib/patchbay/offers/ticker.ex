defmodule Patchbay.Offers.Ticker do
  @moduledoc """
  The purchases the home page's ticker runs, from the market's own events:
  the largest bought since midnight UTC first, then the ten most recent
  others, each with the offer it bought, the placement it runs in and what it
  paid.

  Only purchases in open placements whose campaign Patchbay would show there
  now (`Patchbay.Offers.Eligibility.runnable/2`), so a campaign Patchbay
  pulled, or an advertiser it blocked, is never named. A purchase is a public
  fact of the market and naming it shows no offer to a reader, so nothing
  here writes a delivery. Read as the system, in the same few reads however
  many placements there are; nothing while no market is set.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.Eligibility

  @system %{role: :system}
  @recent 10

  @type purchase :: %{lease: map(), campaign: map(), placement: map(), top?: boolean()}

  @doc "The ticker's purchases in the order it runs them, the day's largest marked `top?`."
  @spec read() :: [purchase()]
  def read do
    if Offers.enabled?(), do: read_enabled(), else: []
  end

  defp read_enabled do
    %{chain_id: chain_id} = Offers.chain()
    market = Offers.market()

    case Offers.open_placements!(chain_id, market, actor: @system) do
      [] -> []
      placements -> purchases(chain_id, market, placements)
    end
  end

  defp purchases(chain_id, market, placements) do
    ids = Enum.map(placements, & &1.placement_id)
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00])
    today = Offers.bought_since!(chain_id, market, ids, midnight, actor: @system)
    latest = Offers.latest_purchases!(chain_id, market, ids, actor: @system)

    named =
      placements
      |> Eligibility.runnable(Enum.uniq_by(today ++ latest, & &1.id))
      |> Map.new(fn {lease, campaign, placement} ->
        {lease.id, %{lease: lease, campaign: campaign, placement: placement}}
      end)

    top = Enum.find_value(today, &named[&1.id])

    others =
      latest
      |> Enum.flat_map(&List.wrap(named[&1.id]))
      |> Enum.reject(&(top != nil and &1.lease.id == top.lease.id))
      |> Enum.take(@recent)

    List.wrap(top && Map.put(top, :top?, true)) ++ Enum.map(others, &Map.put(&1, :top?, false))
  end
end
