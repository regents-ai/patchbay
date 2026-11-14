defmodule Patchbay.Offers.Events do
  @moduledoc """
  The market's logs as rows: the four events Patchbay keeps
  (`PlacementCreated`, `PlacementTerminated`, `LeasePurchased` and
  `LeaseSettled`), decoded with the contract's own ABI. Hashes and addresses
  are lowercase `0x` hex, amounts are USDC base units as decimals, and times
  are the chain's seconds.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.Contract.EventFilters

  @kept ~w(PlacementCreated PlacementTerminated LeasePurchased LeaseSettled)
  @reasons [:bought_out, :expired, :terminated]

  @doc "The first topic of each kept event, for the log search."
  @spec topics() :: [String.t()]
  def topics, do: for(selector <- selectors(), do: hex(selector.method_id))

  @doc """
  The rows for `logs`, in chain order, each as `{kind, fields}` where kind is
  `:placement`, `:termination`, `:lease` or `:settlement`.
  """
  @spec rows(pos_integer(), [map()]) :: [{atom(), map()}]
  def rows(chain_id, logs) do
    logs
    |> Enum.map(&row(chain_id, &1))
    |> Enum.sort_by(fn {_kind, fields} -> {fields.block_number, fields.log_index} end)
  end

  defp row(chain_id, log) do
    [topic | _indexed] = log["topics"]
    selector = Enum.find(selectors(), &(hex(&1.method_id) == String.downcase(topic)))
    event = Ethers.Event.decode(log, selector)

    where = %{
      chain_id: chain_id,
      market: String.downcase(log["address"]),
      transaction_hash: String.downcase(event.transaction_hash),
      log_index: event.log_index,
      block_number: event.block_number,
      block_hash: String.downcase(event.block_hash)
    }

    {kind, fields} = fields(selector.function, event.topics, event.data)
    {kind, Map.merge(where, fields)}
  end

  defp fields(
         "PlacementCreated",
         [_name, placement_id, source_id],
         [capacity, duration, bump, floor, policy_hash, metadata_uri]
       ) do
    source_id = hex(source_id)

    {:placement,
     %{
       placement_id: placement_id,
       source_id: source_id,
       capacity: capacity,
       duration_seconds: duration,
       min_bump_bps: bump,
       floor_usdc: Decimal.new(floor),
       policy_hash: hex(policy_hash),
       metadata_uri: metadata_uri,
       source_origin: source_origin(metadata_uri, source_id)
     }}
  end

  defp fields("PlacementTerminated", [_name, placement_id], [terminated_at]) do
    {:termination, %{placement_id: placement_id, terminated_at: time(terminated_at)}}
  end

  defp fields(
         "LeasePurchased",
         [_name, placement_id, slot, buyer],
         [campaign_id, paid, starts_at, ends_at, nonce]
       ) do
    {:lease,
     %{
       placement_id: placement_id,
       slot: slot,
       buyer: String.downcase(buyer),
       campaign_id: hex(campaign_id),
       paid_usdc: Decimal.new(paid),
       starts_at: time(starts_at),
       ends_at: time(ends_at),
       nonce: nonce
     }}
  end

  defp fields(
         "LeaseSettled",
         [_name, placement_id, slot, buyer],
         [nonce, reason, settled_at, refund, publisher, fee]
       ) do
    {:settlement,
     %{
       placement_id: placement_id,
       slot: slot,
       buyer: String.downcase(buyer),
       nonce: nonce,
       reason: Enum.fetch!(@reasons, reason),
       settled_at: time(settled_at),
       refund_usdc: Decimal.new(refund),
       publisher_usdc: Decimal.new(publisher),
       fee_usdc: Decimal.new(fee)
     }}
  end

  @doc """
  The listed site a placement is for: the last part of its address, when its
  hash is the placement's source id, and otherwise none.
  """
  @spec source_origin(String.t(), String.t()) :: String.t() | nil
  def source_origin(metadata_uri, source_id) do
    with %URI{path: "/" <> path} <- URI.parse(metadata_uri),
         origin = path |> String.split("/") |> List.last(),
         true <- Offers.hash(origin) == source_id do
      origin
    else
      _other -> nil
    end
  end

  defp selectors, do: Enum.filter(EventFilters.__events__(), &(&1.function in @kept))

  defp time(seconds), do: DateTime.from_unix!(seconds)
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
