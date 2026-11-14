defmodule Patchbay.Offers.Board do
  @moduledoc """
  The market as Patchbay's record has it: each open placement, and for each
  of its slots the offer it shows now, what that lease paid, when it ends and
  the least the next purchase must pay. Read from the market's own events
  (`Patchbay.Offers.Placement` and `Patchbay.Offers.Lease`); the page reads
  the chain again at the latest block before it builds a purchase.
  """

  alias Patchbay.Offers

  @bps 10_000

  @type slot :: %{
          slot: non_neg_integer(),
          lease: map() | nil,
          offer: map() | nil,
          minimum_usdc: non_neg_integer()
        }

  @doc "Every open placement with its slots, and whether the record is up to date."
  @spec read() :: %{placements: [%{placement: map(), slots: [slot()]}], fresh?: boolean()}
  def read do
    %{chain_id: chain_id} = Offers.chain()
    market = Offers.market()

    placements = Offers.open_placements!(chain_id, market)
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
