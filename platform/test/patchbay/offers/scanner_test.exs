defmodule Patchbay.Offers.ScannerTest do
  @moduledoc """
  The market's reader (`Patchbay.Offers.Scanner`, run by
  `Patchbay.Offers.ReadMarket`) against a chain the test holds
  (`PatchbayTest.OfferChain`): each event is recorded once as the chain gave
  it, a range the node refuses is read in halves, a node that does not answer
  ends the pass, and where the chain's history changes the rows saved first
  are kept, the transaction is named once in a warning, and reading goes on.
  """

  use Patchbay.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
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
    assert %{next_block: 11, head_block: 10} = cursor()

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

  test "an event read again with other values keeps the row saved first, and reading goes on" do
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)
    assert :ok = pass()
    [%{transaction_hash: transaction}] = Ash.read!(Lease)

    # The same log, the same transaction and place in it, now with another
    # price, and a placement made after it.
    Chain.lease!(6, 1, 0, @buyer, @campaign, 6_000_000)
    Chain.placement!(12, 2, "openai.com")
    Chain.mine!(14)

    {result, log} = with_log(&pass/0)

    assert result == :ok
    assert [lease] = Ash.read!(Lease)
    assert Decimal.equal?(lease.paid_usdc, 5_500_000)
    assert [%{placement_id: 2}] = Ash.read!(Placement)
    assert %{next_block: 15, head_block: 14} = cursor()
    warned_once(log, transaction)
  end

  test "a saved event gone from a block whose hash changed is kept, and reading goes on" do
    Chain.placement!(4, 1, "stripe.com")
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.lease!(7, 1, 1, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)
    assert :ok = pass()
    leases = Ash.read!(Lease)
    %{transaction_hash: transaction} = Enum.find(leases, &(&1.block_number == 6))

    # The lease in block 6 is gone and the block changed; the placement and
    # the lease in block 7 read again as saved.
    Chain.drop_logs!(6)
    Chain.reorg!(6)
    Chain.placement!(12, 2, "openai.com")
    Chain.mine!(14)

    {result, log} = with_log(&pass/0)

    assert result == :ok
    assert [6, 7] = Lease |> Ash.read!() |> Enum.map(& &1.block_number) |> Enum.sort()
    assert [1, 2] = Placement |> Ash.read!() |> Enum.map(& &1.placement_id) |> Enum.sort()
    assert %{next_block: 15} = cursor()
    warned_once(log, transaction)
  end

  test "a saved event gone from a block whose hash is unchanged ends the pass, to be tried again" do
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)
    assert :ok = pass()

    # The node left the log out, yet the block is the one recorded.
    Chain.drop_logs!(6)
    Chain.mine!(14)

    assert {:error, {:log_missing_from_block, 6}} = pass()
    assert %{next_block: 11} = cursor()
    assert [_lease] = Ash.read!(Lease)
  end

  test "a saved transaction read from another block is not saved again, and is named once in a pass" do
    Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
    Chain.mine!(10)
    assert :ok = pass()
    [%{transaction_hash: transaction}] = Ash.read!(Lease)

    # The transaction lands again in block 8, at another place in it; blocks
    # 6 and 8 are read in different pieces.
    Chain.move_logs!(6, 8, 3)
    Chain.reorg!(6)
    Chain.reorg!(8)
    Chain.refuse_wider_than!(2)
    Chain.mine!(12)

    {result, log} = with_log(&pass/0)

    assert result == :ok
    assert [%{block_number: 6, log_index: 0}] = Ash.read!(Lease)
    assert %{next_block: 13} = cursor()
    warned_once(log, transaction)
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

    test "ends for a market Patchbay no longer reads or a node on another chain, never for a changed history" do
      assert {:cancel, :not_this_market} =
               perform("0x00000000000000000000000000000000000000bb")

      Chain.start!(1)
      assert {:cancel, {:wrong_chain, 1}} = perform(market())

      Chain.start!()
      Chain.lease!(6, 1, 0, @buyer, @campaign, 5_500_000)
      Chain.mine!(10)
      assert {:snooze, 300} = perform(market())
      Chain.lease!(6, 1, 0, @buyer, @campaign, 6_000_000)
      assert {:snooze, 300} = perform(market())
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

  # The pass logged one warning, and it names the market and `transaction`.
  defp warned_once(log, transaction) do
    assert [warning] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]"))
    assert warning =~ market() and warning =~ transaction
  end

  defp perform(market),
    do: ReadMarket.perform(%Oban.Job{args: %{"chain_id" => 8453, "market" => market}})
end
