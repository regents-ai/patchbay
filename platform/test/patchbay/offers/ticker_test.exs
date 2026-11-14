defmodule Patchbay.Offers.TickerTest do
  @moduledoc """
  The purchases the home page's ticker runs (`Patchbay.Offers.Ticker`) and
  the sites the directory marks as showing an offer
  (`Patchbay.Offers.Board.sponsored/0`): only what Patchbay would show,
  never a delivery, nothing while no market is set, and the same few reads
  however many placements there are.

  The moderator list is application-wide, so this file runs alone.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import PatchbayTest.OfferFixtures

  alias Patchbay.Offers
  alias Patchbay.Offers.{Board, Ticker}

  @system %{role: :system}

  setup do
    offers_on!()
    placement!(1, "stripe.com")
    placement!(2, "openai.com")
    placement!(9, "general")
    advertiser = person!(wallet())
    %{advertiser: advertiser, campaign: shown_campaign!(advertiser)}
  end

  test "the day's largest purchase first and marked, then the ten most recent others", %{
    campaign: campaign
  } do
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00])
    yesterday = DateTime.add(midnight, -3600)

    # The largest of all, but bought before midnight UTC.
    buy!(100, 1, campaign, 900, starts_at: yesterday)
    buy!(101, 2, campaign, 50)
    for block <- 102..112, do: buy!(block, 9, campaign, block - 100)

    assert [{101, true} | others] = Enum.map(Ticker.read(), &{&1.lease.block_number, &1.top?})
    assert others == Enum.map(112..103//-1, &{&1, false})
  end

  test "each purchase carries what it bought and where it runs", %{campaign: campaign} do
    buy!(100, 9, campaign, 12)

    assert [
             %{
               top?: true,
               campaign: %{title: "Acme payments"},
               placement: placement,
               lease: lease
             }
           ] =
             Ticker.read()

    assert placement.source_origin == "general"
    assert Decimal.equal?(lease.paid_usdc, 12_000_000)
  end

  test "a purchase Patchbay would not show is never named, and nothing is delivered", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    pulled = shown_campaign!(advertiser, %{title: "Pulled"})
    buy!(100, 1, campaign, 5)
    buy!(101, 1, pulled, 500)
    Offers.pull_campaign!(pulled.campaign_id, %{reason: "Misleading"}, actor: moderator())

    assert [%{lease: %{block_number: 100}, top?: true}] = Ticker.read()
    assert Ash.read!(Offers.Delivery, actor: @system) == []
  end

  test "the sites showing an offer, each with its soonest-ending offer's term", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    lease!(1, 0, campaign)

    soonest =
      lease!(1, 1, campaign, %{
        starts_at: DateTime.add(now, -48 * 3600),
        ends_at: DateTime.add(now, 24 * 3600)
      })

    # General is no site; a pulled campaign is shown nowhere.
    lease!(9, 0, campaign)
    pulled = shown_campaign!(advertiser, %{title: "Pulled"})
    lease!(2, 0, pulled)
    Offers.pull_campaign!(pulled.campaign_id, %{reason: "Misleading"}, actor: moderator())

    assert Board.sponsored() == %{
             "stripe.com" => %{starts_at: soonest.starts_at, ends_at: soonest.ends_at}
           }
  end

  test "the same reads for two sites' placements as for twenty", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    # A campaign for one kind of site reads the sites' kinds too.
    kind = shown_campaign!(advertiser, %{title: "Companies", audience: :group, group: :company})
    lease!(1, 0, campaign)
    lease!(2, 0, kind)

    few = {queries(&Board.sponsored/0), queries(&Ticker.read/0)}

    for id <- 10..27 do
      placement!(id, "site#{id}.example")
      lease!(id, 0, if(rem(id, 2) == 0, do: campaign, else: kind))
    end

    # Ten sites run the all-sites campaign; the others' kind is not known, so
    # theirs is not shown.
    assert {map_size(Board.sponsored()), length(Ticker.read())} == {10, 10}
    assert {queries(&Board.sponsored/0), queries(&Ticker.read/0)} == few
  end

  test "nothing while no market is set", %{campaign: campaign} do
    buy!(100, 1, campaign, 5)
    offers_on!(market_address: nil)

    assert Ticker.read() == []
    assert Board.sponsored() == %{}
  end

  defp buy!(block, placement_id, campaign, usdc, attrs \\ []) do
    lease!(
      placement_id,
      rem(block, 3),
      campaign,
      Map.merge(%{block_number: block, paid_usdc: Decimal.new(usdc * 1_000_000)}, Map.new(attrs))
    )
  end

  # How many database queries `read` makes.
  defp queries(read) do
    handler = "ticker-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:patchbay, :repo, :query], &__MODULE__.counted/4, self())
    read.()
    :telemetry.detach(handler)
    count(0)
  end

  @doc false
  def counted(_event, _measurements, _metadata, test), do: send(test, :query)

  defp count(seen) do
    receive do
      :query -> count(seen + 1)
    after
      0 -> seen
    end
  end
end
