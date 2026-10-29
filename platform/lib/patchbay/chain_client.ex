defmodule Patchbay.ChainClient do
  @moduledoc """
  JSON-RPC reads at the latest block of the chain a Credits purchase names.
  Every read is at `latest`: never count confirmations and never wait for
  `safe` or `finalized`. The node is the site's own for the chain
  (`config :patchbay, :chain_nodes`), never the public address a wallet adds
  the chain with. Regent Credits checks a purchase through `transaction/2`,
  `receipt/2` and `block_number/1`; Regent Points reads the NFTs a person
  holds through `rpc/3`.
  """

  @behaviour RegentCredits.ChainClient
  @behaviour RegentPoints.ChainClient

  @doc "The transaction sent as `hash`, or `nil` while the chain does not know it."
  @impl RegentCredits.ChainClient
  def transaction(chain, hash), do: rpc(chain, "eth_getTransactionByHash", [hash])

  @doc "The receipt for `hash`, or `nil` while it has not landed."
  @impl RegentCredits.ChainClient
  def receipt(chain, hash), do: rpc(chain, "eth_getTransactionReceipt", [hash])

  @doc "The newest block number."
  @impl RegentCredits.ChainClient
  def block_number(chain) do
    with {:ok, "0x" <> hex} <- rpc(chain, "eth_blockNumber", []) do
      {:ok, String.to_integer(hex, 16)}
    end
  end

  @doc "`eth_getLogs` with `filter` as given."
  @impl RegentCredits.ChainClient
  def logs(chain, filter), do: rpc(chain, "eth_getLogs", [filter])

  @doc """
  One JSON-RPC request to the chain's node; one that gets no answer counts in
  `health.chain_request_failures.total` under `scope`, the caller's fixed name.
  """
  @impl RegentPoints.ChainClient
  def rpc(%{chain_id: chain_id}, method, params, scope \\ "wallet") when is_binary(scope) do
    url = :patchbay |> Application.fetch_env!(:chain_nodes) |> Map.fetch!(chain_id)
    chain = %{chain_id: chain_id, scope: scope}

    case Req.post(url,
           json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{body: %{"error" => error}}} -> failed(chain, method, {:rpc, error})
      {:ok, %{status: status}} -> failed(chain, method, {:http, status})
      {:error, error} -> failed(chain, method, error)
    end
  end

  defp failed(chain, method, reason) do
    :telemetry.execute([:patchbay, :chain, :failure], %{count: 1}, %{
      method: method,
      class: class(reason),
      chain_id: chain.chain_id,
      scope: chain.scope
    })

    {:error, reason}
  end

  defp class({:rpc, _error}), do: "rpc"
  defp class({:http, status}), do: "http_#{status}"

  defp class(%Req.TransportError{reason: reason}) when reason in [:timeout, :connect_timeout],
    do: "timeout"

  defp class(_transport), do: "transport"
end
