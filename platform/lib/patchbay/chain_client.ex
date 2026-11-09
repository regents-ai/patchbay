defmodule Patchbay.ChainClient do
  @moduledoc """
  JSON-RPC reads at the latest block of a chain, through the site's own node
  for it (`config :patchbay, :chain_nodes`), never the public address a wallet
  adds the chain with. Regent Points reads the NFTs a person holds through
  `rpc/3`.
  """

  @behaviour RegentPoints.ChainClient

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
