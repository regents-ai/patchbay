defmodule Patchbay.Offers.ScannerTest do
  @moduledoc """
  The market's reader (`Patchbay.Offers.Scanner`, run by
  `Patchbay.Offers.ReadMarket`) against a chain the test holds
  (`PatchbayTest.OfferChain`): each event is recorded once as the chain gave
  it, a range the node refuses is read in halves, a node that does not answer
  ends the pass, and a change in the chain's history stops the reading at its
  block until a person clears it.
  """

  use Patchbay.DataCase, async: false

  import PatchbayTest.OfferFixtures, only: [offers_on!: 1, market: 0]

  alias Patchbay.Offers
  alias Patchbay.Offers.{Lease, Placement, ReadMarket, Scanner, Watch}
  alias PatchbayTest.OfferChain, as: Chain

  @moduletag :capture_log

  @buyer "0x00000000000000000000000000000000000000b1"
  @campaign "0x" <> String.duplicate("c", 64)

  setup do
    offers_on!(client: Chain, from_block: 0)
    Chain.start!()
  end

  test "each event is recorded once, as the chain gave it, and reading again changes nothing" do
    Chain.placement!(5, 1, "stripe.com")
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)

    assert :ok = pass()
    assert [%{placement_id: 1, source_origin: "stripe.com", capacity: 3}] = Ash.read!(Placement)
    assert [%{slot: 0, buyer: @buyer, campaign_id: @campaign} = lease] = Ash.read!(Lease)
    assert Decimal.equal?(lease.paid_usdc, 5_500_000)
    assert %{next_block: 11, head_block: 10, rescan_from: nil} = cursor()

    Chain.mine!(20)

    assert :ok = pass()
    assert [_placement] = Ash.read!(Placement)
    assert [_lease] = Ash.read!(Lease)
    assert %{next_block: 21, head_block: 20} = cursor()
  end

  test "a range the node will not answer whole is read in halves, each block once and in order" do
    Chain.placement!(3, 1, "stripe.com")
    Chain.mine!(8)
    Chain.refuse_wider_than!(2)

    assert :ok = pass()
    assert [%{placement_id: 1}] = Ash.read!(Placement)
    assert [{0, 8} | _halves] = Chain.asked()

    answered =
      for {from, to} <- Chain.asked(), to - from < 2, into: [], do: Enum.to_list(from..to)

    assert List.flatten(answered) == Enum.to_list(0..8)
  end

  test "a node that answers nothing ends the pass, and the next pass reads on" do
    Chain.placement!(4, 1, "stripe.com")
    Chain.mine!(10)
    Chain.answering!(false)

    assert {:error, :unavailable} = pass()
    assert Ash.read!(Placement) == []

    Chain.answering!(true)

    assert :ok = pass()
    assert [_placement] = Ash.read!(Placement)
  end

  test "an event read again with other values stops the reading at its block, and nothing is rewritten" do
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)
    assert :ok = pass()

    # The same log, the same transaction and place in it, now with another price.
    Chain.lease!(6, 1, 0, @buyer, @campaign, 6_000_000)
    Chain.mine!(12)

    assert {:stopped, 6} = pass()
    assert %{rescan_from: 6, next_block: 11} = cursor()
    assert [lease] = Ash.read!(Lease)
    assert Decimal.equal?(lease.paid_usdc, 5_500_000)

    # Stopped, the reader asks the chain for nothing until a person clears it.
    asked = Chain.asked()
    assert {:stopped, 6} = pass()
    assert Chain.asked() == asked
  end

  test "a recorded event gone from its block stops the reading only when the block itself changed" do
    Chain.placement!(4, 1, "stripe.com")
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)
    assert :ok = pass()

    # The node left the log out, yet the block is the one recorded: the pass
    # fails, to be tried again, and nothing stops.
    Chain.drop_logs!(6)
    assert {:error, {:log_missing_from_block, 6}} = pass()
    assert %{rescan_from: nil, next_block: 11} = cursor()

    Chain.reorg!(6)
    assert {:stopped, 6} = pass()
    assert [_lease] = Ash.read!(Lease)
  end

  describe "the reading job" do
    test "reads the market and comes back in five minutes" do
      Chain.placement!(2, 1, "stripe.com")
      Chain.mine!(4)

      assert {:snooze, 300} = perform(market())
      assert [_placement] = Ash.read!(Placement)
    end

    test "waits a minute for a node that does not answer" do
      Chain.answering!(false)
      assert {:snooze, 60} = perform(market())
    end

    test "ends for a market Patchbay no longer reads, a node on another chain, or a stopped reading" do
      assert {:cancel, :not_this_market} =
               perform("0x00000000000000000000000000000000000000bb")

      Chain.start!(1)
      assert {:cancel, {:wrong_chain, 1}} = perform(market())

      Chain.start!()
      Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
      Chain.mine!(10)
      assert {:snooze, 300} = perform(market())
      Chain.lease!(6, 1, 0, @buyer, @campaign, 6_000_000)
      assert {:cancel, {:stopped, 6}} = perform(market())
    end

    test "a landed purchase brings the next read to ten seconds away, never later" do
      args = %{chain_id: 8453, market: market()}
      Oban.insert!(ReadMarket.new(args, schedule_in: 300))

      assert :ok = Watch.refresh()
      assert [%{scheduled_at: soon}] = Patchbay.Repo.all(Oban.Job)
      assert DateTime.diff(soon, DateTime.utc_now()) in 0..10

      assert :ok = Watch.refresh()
      assert [%{scheduled_at: ^soon}] = Patchbay.Repo.all(Oban.Job)
    end
  end

  defp pass, do: Scanner.pass(Chain, 8453, market())
  defp cursor, do: Offers.get_cursor!(8453, market())

  defp perform(market),
    do: ReadMarket.perform(%Oban.Job{args: %{"chain_id" => 8453, "market" => market}})
end
