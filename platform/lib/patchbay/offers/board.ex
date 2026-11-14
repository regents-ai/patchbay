defmodule Patchbay.Offers.Board do
  @moduledoc """
  The market as Patchbay's record has it: each open placement, and for each
  of its slots the offer it shows now, what that lease paid, when it ends and
  the least the next purchase must pay. Read from the market's own events
  (`Patchbay.Offers.Placement` and `Patchbay.Offers.Lease`); the page reads
  the chain again at the latest block before it builds a purchase.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.Eligibility
  alias Patchbay.Offers.Source

  @bps 10_000

  @type slot :: %{
          slot: non_neg_integer(),
          lease: map() | nil,
          offer: map() | nil,
          minimum_usdc: non_neg_integer()
        }

  @doc """
  Every open placement with its slots, General's and CVE incidents' first,
  then each site's by its address (`Source.rank/1`), and whether the record is
  up to date. The same few reads however many placements there are.
  """
  @spec read() :: %{placements: [%{placement: map(), slots: [slot()]}], fresh?: boolean()}
  def read do
    %{chain_id: chain_id} = Offers.chain()
    market = Offers.market()

    placements =
      chain_id
      |> Offers.open_placements!(market)
      |> Enum.sort_by(&Source.rank(&1.source_origin))

    current = chain_id |> Offers.live_leases!(market) |> Enum.uniq_by(&{&1.placement_id, &1.slot})

    offers =
      current
      |> Enum.map(& &1.campaign_id)
      |> Offers.campaigns_by_ids!()
      |> Map.new(&{&1.campaign_id, &1})

    leases = Map.new(current, &{{&1.placement_id, &1.slot}, &1})

    %{
      placements:
        Enum.map(placements, fn placement ->
          %{placement: placement, slots: slots(placement, leases, offers)}
        end),
      fresh?: fresh?(chain_id, market)
    }
  end

  @doc """
  The listed sites showing a paid offer now, each with the term of its
  soonest-ending one: a live lease, in an open placement for the site, whose
  campaign Patchbay would show there (`Eligibility.runnable/2`). The same few
  reads however many sites and placements there are. None while no market is
  set.
  """
  @spec sponsored() :: %{String.t() => %{starts_at: DateTime.t(), ends_at: DateTime.t()}}
  def sponsored do
    if Offers.enabled?(), do: read_sponsored(), else: %{}
  end

  defp read_sponsored do
    %{chain_id: chain_id} = Offers.chain()
    market = Offers.market()

    placements =
      chain_id
      |> Offers.open_placements!(market)
      |> Enum.filter(&Source.site?(&1.source_origin))

    ids = MapSet.new(placements, & &1.placement_id)

    leases =
      chain_id
      |> Offers.live_leases!(market)
      |> Enum.uniq_by(&{&1.placement_id, &1.slot})
      |> Enum.filter(&(&1.placement_id in ids))

    placements
    |> Eligibility.runnable(leases)
    |> Enum.group_by(
      fn {_lease, _campaign, placement} -> placement.source_origin end,
      &elem(&1, 0)
    )
    |> Map.new(fn {origin, leases} ->
      {origin, leases |> Enum.min_by(& &1.ends_at, DateTime) |> Map.take([:starts_at, :ends_at])}
    end)
  end

  @doc """
  The least the next purchase of a slot must pay: the floor while the slot is
  empty or its lease has run out, else what the lease paid plus the
  placement's step, rounded up, as the market works it out.
  """
  @spec minimum(map(), map() | nil) :: non_neg_integer()
  def minimum(placement, nil), do: Decimal.to_integer(placement.floor_usdc)

  def minimum(placement, lease) do
    paid = Decimal.to_integer(lease.paid_usdc)
    div(paid * (@bps + placement.min_bump_bps) + @bps - 1, @bps)
  end

  defp slots(placement, leases, offers) do
    for slot <- 0..(placement.capacity - 1) do
      lease = leases[{placement.placement_id, slot}]

      %{
        slot: slot,
        lease: lease,
        offer: lease && offers[lease.campaign_id],
        minimum_usdc: minimum(placement, lease)
      }
    end
  end

  defp fresh?(chain_id, market) do
    case Offers.get_cursor(chain_id, market, load: [:fresh?]) do
      {:ok, %{fresh?: fresh?}} -> fresh?
      {:ok, nil} -> false
    end
  end
end
