defmodule PatchbayWeb.PaymentLimit do
  @moduledoc """
  Gives each wallet a share of payment requests a minute: the hosted tools
  that act for a wallet, and the HTTP payment intent endpoints. It lives in
  this node's memory, which is the whole of Patchbay: the site runs on one
  machine.

  The share is counted by the wallet a request acts for, never by the address
  it came from, so wallets behind one proxy do not spend each other's share,
  and a wallet's share is spent only by naming that wallet. Ten a minute is
  more than a whole purchase takes: the terms, the payment, the status read
  and the signed action after. A refused request has done nothing.
  """

  use Hammer, backend: :ets

  @default_payments_per_minute 10
  @window :timer.minutes(1)

  @error "Too many payment requests for this wallet. Wait a minute, then try again."

  @doc "Draws one request on the wallet's share; `{:wait, seconds}` once it is spent."
  @spec check(String.t()) :: :ok | {:wait, pos_integer()}
  def check(wallet) when is_binary(wallet) do
    case hit(String.downcase(wallet), @window, payments_per_minute()) do
      {:allow, _count} -> :ok
      {:deny, wait} -> {:wait, wait |> div(1000) |> max(1)}
    end
  end

  @doc "The refusal every door answers with, naming the seconds until the share is whole again."
  @spec refusal(pos_integer()) :: map()
  def refusal(seconds),
    do: %{error: @error, problem_code: "rate_limited", retry_after_seconds: seconds}

  defp payments_per_minute do
    Application.get_env(:patchbay, :payments_per_minute, @default_payments_per_minute)
  end
end
