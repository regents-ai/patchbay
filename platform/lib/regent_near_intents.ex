# A sprint copy (NEAR hackathon, 14 Nov 2026). The shared `near_intents` package
# in elixir-utils carries this module with this exact name, functions and return
# shapes; once Patchbay pins it, delete this file and nothing else changes.
defmodule RegentNearIntents do
  @moduledoc """
  The NEAR Intents 1Click service (`https://1click.chaindefuser.com`), for one
  route: NEAR (`nep141:wrap.near`) in, an exact amount of USDC on Base out.

  It only reads: a price, a deposit address and a swap's progress. The person
  or agent sends NEAR from their own wallet to the deposit address; nothing
  here holds or moves money. No state, no database, no key.
  """

  @base_url "https://1click.chaindefuser.com"
  @near "nep141:wrap.near"
  @base_usdc "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near"

  # How long a deposit address takes deposits, and the slippage allowed on the
  # NEAR side, in basis points.
  @deposit_window_s 3_600
  @slippage_bps 100

  @states %{
    "PENDING_DEPOSIT" => :pending_deposit,
    "INCOMPLETE_DEPOSIT" => :pending_deposit,
    "KNOWN_DEPOSIT_TX" => :processing,
    "PROCESSING" => :processing,
    "SUCCESS" => :success,
    "REFUNDED" => :refunded,
    "FAILED" => :failed
  }

  @type state :: :pending_deposit | :processing | :success | :refunded | :failed
  @type error :: {:error, %{reason: atom(), message: String.t()}}

  @doc "Every asset the service swaps."
  @spec tokens() :: {:ok, [map()]} | error()
  def tokens do
    with {:ok, tokens} <- request(method: :get, url: "/v0/tokens") do
      {:ok,
       Enum.map(tokens, fn token ->
         %{
           asset_id: token["assetId"],
           symbol: token["symbol"],
           blockchain: token["blockchain"],
           decimals: token["decimals"],
           price: token["price"]
         }
       end)}
    end
  end

  @doc """
  The NEAR it takes to deliver exactly `usdc_amount` (USDC base units) to
  `recipient` on Base, with any refund to the NEAR account `refund_to`. A
  `dry: false` quote also opens a deposit address.
  """
  @spec quote(%{
          usdc_amount: pos_integer(),
          recipient: String.t(),
          refund_to: String.t(),
          dry: boolean()
        }) :: {:ok, map()} | error()
  def quote(%{usdc_amount: amount, recipient: recipient, refund_to: refund_to, dry: dry}) do
    deadline = DateTime.add(DateTime.utc_now(), @deposit_window_s) |> DateTime.to_iso8601()

    body = %{
      dry: dry,
      swapType: "EXACT_OUTPUT",
      slippageTolerance: @slippage_bps,
      originAsset: @near,
      depositType: "ORIGIN_CHAIN",
      destinationAsset: @base_usdc,
      amount: Integer.to_string(amount),
      refundTo: refund_to,
      refundType: "ORIGIN_CHAIN",
      recipient: recipient,
      recipientType: "DESTINATION_CHAIN",
      deadline: deadline
    }

    with {:ok, %{"quote" => quote} = raw} <- request(method: :post, url: "/v0/quote", json: body) do
      {:ok,
       %{
         amount_in: quote["amountIn"],
         amount_in_formatted: quote["amountInFormatted"],
         amount_out: quote["amountOut"],
         amount_out_formatted: quote["amountOutFormatted"],
         time_estimate_s: quote["timeEstimate"],
         deadline: datetime(quote["deadline"]),
         deposit_address: quote["depositAddress"],
         raw: raw
       }}
    end
  end

  @doc "Where the swap behind `deposit_address` stands, with its transactions once known."
  @spec status(String.t()) ::
          {:ok, %{state: state(), origin_tx: String.t() | nil, destination_tx: String.t() | nil, raw: map()}}
          | error()
  def status(deposit_address) do
    with {:ok, raw} <-
           request(method: :get, url: "/v0/status", params: [depositAddress: deposit_address]),
         {:ok, state} <- state(raw["status"]) do
      details = raw["swapDetails"] || %{}

      {:ok,
       %{
         state: state,
         origin_tx: first_hash(details["originChainTxHashes"]),
         destination_tx: first_hash(details["destinationChainTxHashes"]),
         raw: raw
       }}
    end
  end

  defp state(status) do
    case Map.fetch(@states, status) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, %{reason: :unknown_status, message: "Unknown swap status: #{inspect(status)}"}}
    end
  end

  defp first_hash([%{"hash" => hash} | _rest]), do: hash
  defp first_hash(_none), do: nil

  defp datetime(nil), do: nil

  defp datetime(text) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(text)
    datetime
  end

  defp request(options) do
    [base_url: @base_url, retry: false, receive_timeout: 15_000]
    |> Keyword.merge(options)
    |> Req.new()
    |> Req.merge(Application.get_env(:patchbay, :near_intents_req_options, []))
    |> Req.request()
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404, body: body}} ->
        {:error, %{reason: :not_found, message: message(body)}}

      {:ok, %{status: status, body: body}} when status in 400..499 ->
        {:error, %{reason: :bad_request, message: message(body)}}

      {:ok, %{status: status}} ->
        {:error, %{reason: :unavailable, message: "The service answered #{status}."}}

      {:error, exception} ->
        {:error, %{reason: :unavailable, message: Exception.message(exception)}}
    end
  end

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(_body), do: "The service refused the request."
end
