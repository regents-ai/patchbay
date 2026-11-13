defmodule Patchbay.Offers.Client do
  @moduledoc """
  The chain the market is on, as Patchbay reads it, always at `latest`: the
  site's own node in development (`Patchbay.Offers.Node`), a stand-in the
  test describes in tests. Every call answers `{:error, :unavailable}` when the
  node does not answer, which is the provider's weather, not a fault.
  """

  @type head :: %{number: non_neg_integer(), hash: String.t()}

  @callback chain_id() :: {:ok, pos_integer()} | {:error, term()}
  @callback head() :: {:ok, head()} | {:error, term()}
  @callback block_hash(non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  @callback logs(market :: String.t(), [String.t()], non_neg_integer(), non_neg_integer()) ::
              {:ok, [map()]} | {:error, :too_many_results | :unavailable | term()}
  @callback call(to :: String.t(), data :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "The client the site reads the market through."
  @spec configured() :: module()
  def configured, do: Patchbay.Offers.settings()[:client]
end

defmodule Patchbay.Offers.Node do
  @moduledoc """
  `Patchbay.Offers.Client` over JSON-RPC, through the site's own node for the
  market's chain (`Patchbay.ChainClient`), reading `latest` wherever a block
  goes. Hashes and addresses come back lowercase.
  """

  @behaviour Patchbay.Offers.Client

  alias Patchbay.ChainClient

  @scope "offers"

  @impl true
  def chain_id do
    with {:ok, id} <- rpc("eth_chainId", []), do: {:ok, quantity(id)}
  end

  @impl true
  def head do
    case rpc("eth_getBlockByNumber", ["latest", false]) do
      {:ok, %{"number" => number, "hash" => hash}} ->
        {:ok, %{number: quantity(number), hash: String.downcase(hash)}}

      {:ok, _other} ->
        {:error, :unavailable}

      error ->
        error
    end
  end

  @impl true
  def block_hash(number) do
    case rpc("eth_getBlockByNumber", [hex(number), false]) do
      {:ok, %{"hash" => hash}} -> {:ok, String.downcase(hash)}
      {:ok, nil} -> {:ok, nil}
      error -> error
    end
  end

  @impl true
  def logs(market, topics, from, to) do
    case rpc("eth_getLogs", [
           %{address: market, topics: [topics], fromBlock: hex(from), toBlock: hex(to)}
         ]) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:error, {:rpc, _refused}} -> {:error, :too_many_results}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def call(to, data), do: rpc("eth_call", [%{to: to, data: data}, "latest"])

  defp rpc(method, params) do
    case ChainClient.rpc(%{chain_id: Patchbay.Offers.chain().chain_id}, method, params, @scope) do
      {:ok, result} -> {:ok, result}
      {:error, {:rpc, _error}} = refused -> refused
      {:error, {:http, status}} when status == 429 or status >= 500 -> {:error, :unavailable}
      {:error, {:http, status}} -> {:error, {:http, status}}
      {:error, _transport} -> {:error, :unavailable}
    end
  end

  defp hex(number), do: "0x" <> Integer.to_string(number, 16)
  defp quantity("0x" <> digits), do: String.to_integer(digits, 16)
end
