defmodule PatchbayTest.OfferChain do
  @moduledoc """
  A chain for agent offers tests, as `Patchbay.Offers.Client` reads one, held
  in the running test's own process: its head, each block's hash, the
  market's logs, encoded as a node returns them, and what the market and
  USDC answer to calls. A test switches offers on with this client
  (`PatchbayTest.OfferFixtures.offers_on!(client: PatchbayTest.OfferChain)`)
  and sets the chain up from its own process. The chain is read there, and
  from the processes the test started, which name it among their callers: a
  LiveView under test and the reads it runs.

  Every range of logs asked for is noted (`asked/0`), and the node can be
  made to refuse a range wider than some number of blocks, or to answer
  nothing at all.
  """

  @behaviour Patchbay.Offers.Client

  alias Patchbay.Offers
  alias Patchbay.Offers.Contract.EventFilters
  alias RegentChain.Call

  @key __MODULE__

  @doc "A new chain at block 0, with no logs, in this process."
  def start!(chain_id \\ 8453) do
    Process.put(@key, %{
      chain_id: chain_id,
      head: 0,
      hashes: %{},
      logs: [],
      calls: %{},
      widest: nil,
      answering?: true,
      asked: []
    })

    :ok
  end

  @doc "Moves the head to `number`."
  def mine!(number), do: update(&%{&1 | head: number})

  @doc "Gives `block` a hash other than the one it had, as a change in the chain's history does."
  def reorg!(block),
    do: update(&put_in(&1.hashes[block], hash(block + 7_000_000 + map_size(&1.hashes))))

  @doc "Makes the node refuse any range of logs wider than `blocks`."
  def refuse_wider_than!(blocks), do: update(&%{&1 | widest: blocks})

  @doc "Makes the node answer nothing, or answer again."
  def answering!(answering?), do: update(&%{&1 | answering?: answering?})

  @doc "The ranges of logs asked for so far, in order, as `{from, to}`."
  def asked, do: Enum.reverse(state().asked)

  @doc "Answers `data` sent to `to` with `returned`, `0x` hex."
  def answer_call!(to, data, returned), do: update(&put_in(&1.calls[{to, data}], returned))

  @doc """
  Answers the market read `read`, as `Patchbay.Offers.Contract` builds it,
  with `values`, its outputs in order.
  """
  def answer_read!(read, values) do
    answer_call!(
      Offers.market(),
      Ethers.Utils.hex_encode(read.data),
      hex(ABI.TypeEncoder.encode(values, read.selector.returns))
    )
  end

  @doc "Answers USDC's reads of `wallet`: what it holds, and what it lets the market take."
  def usdc!(wallet, balance, allowance) do
    answer_call!(Offers.usdc(), Call.encode("balanceOf(address)", [wallet]), uint(balance))

    answer_call!(
      Offers.usdc(),
      Call.encode("allowance(address,address)", [wallet, Offers.market()]),
      uint(allowance)
    )
  end

  @doc "Takes every log of `block` off the chain."
  def drop_logs!(block),
    do: update(fn state -> %{state | logs: Enum.reject(state.logs, &(&1.block == block))} end)

  @doc """
  A `PlacementCreated` log in `block`: a placement of three 72-hour slots for
  the listed site `origin`, from 5 USDC, under Patchbay's policy.
  """
  def placement!(block, placement_id, origin, index \\ 0) do
    log!(block, index, "PlacementCreated", [placement_id, bytes(Offers.hash(origin))], [
      3,
      72 * 3600,
      1_000,
      5_000_000,
      bytes(Offers.policy_hash()),
      "https://patchbay.help/" <> origin
    ])
  end

  @doc "A `LeasePurchased` log in `block`: `buyer` bought `slot` for `campaign_id`, paying `paid`."
  def lease!(block, placement_id, slot, buyer, campaign_id, paid, index \\ 0) do
    starts_at = System.os_time(:second)

    log!(block, index, "LeasePurchased", [placement_id, slot, bytes(buyer)], [
      bytes(campaign_id),
      paid,
      starts_at,
      starts_at + 72 * 3600,
      1
    ])
  end

  @impl true
  def chain_id, do: answer(fn state -> {:ok, state.chain_id} end)

  @impl true
  def head,
    do: answer(fn state -> {:ok, %{number: state.head, hash: hash_of(state, state.head)}} end)

  @impl true
  def block_hash(number), do: answer(fn state -> {:ok, hash_of(state, number)} end)

  @impl true
  def logs(market, _topics, from, to) do
    update(&%{&1 | asked: [{from, to} | &1.asked]})

    answer(fn state ->
      if state.widest && to - from + 1 > state.widest do
        {:error, :too_many_results}
      else
        {:ok,
         for(
           log <- Enum.reverse(state.logs),
           log.block in from..to//1,
           log.raw["address"] == market,
           do: Map.put(log.raw, "blockHash", hash_of(state, log.block))
         )}
      end
    end)
  end

  @impl true
  def call(to, data) do
    answer(fn state ->
      case state.calls[{to, data}] do
        nil -> {:error, {:rpc, %{"message" => "execution reverted"}}}
        returned -> {:ok, returned}
      end
    end)
  end

  defp log!(block, index, name, indexed, data) do
    selector = Enum.find(EventFilters.__events__(), &(&1.function == name))
    indexed_types = Ethers.ContractHelpers.event_indexed_types(selector)
    data_types = Ethers.ContractHelpers.event_non_indexed_types(selector)

    raw = %{
      "address" => Offers.market(),
      "topics" => [
        hex(selector.method_id)
        | Enum.zip_with(indexed, indexed_types, &hex(ABI.TypeEncoder.encode([&1], [&2])))
      ],
      "data" => hex(ABI.TypeEncoder.encode(data, data_types)),
      "blockNumber" => quantity(block),
      "transactionHash" => hash(block * 1_000 + index + 9_000_000),
      "transactionIndex" => "0x0",
      "logIndex" => quantity(index),
      "removed" => false
    }

    update(fn state ->
      logs = Enum.reject(state.logs, &(&1.block == block and &1.index == index))
      %{state | logs: [%{block: block, index: index, raw: raw} | logs]}
    end)
  end

  defp answer(fun) do
    state = state()
    if state.answering?, do: fun.(state), else: {:error, :unavailable}
  end

  defp state do
    held =
      Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> List.keyfind(dictionary, @key, 0)
          nil -> nil
        end
      end)

    case held do
      {@key, state} -> state
      nil -> raise "start the test chain with start!/0 first"
    end
  end

  defp update(fun) do
    Process.put(@key, fun.(state()))
    :ok
  end

  defp hash_of(state, block), do: Map.get(state.hashes, block, hash(block))

  defp hash(n), do: "0x" <> String.downcase(String.pad_leading(Integer.to_string(n, 16), 64, "0"))
  defp quantity(n), do: "0x" <> Integer.to_string(n, 16)
  defp uint(n), do: hex(ABI.TypeEncoder.encode([n], [{:uint, 256}]))
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
end
