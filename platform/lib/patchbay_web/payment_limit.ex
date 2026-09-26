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

  alias PatchbayWeb.RateLimitHeaders

  @default_payments_per_minute 10
  @window :timer.minutes(1)

  @error "Too many payment requests for this wallet. Wait a minute, then try again."

  @doc """
  Draws one request on the wallet's share: `{:ok, left}` with the requests
  left in it, or `{:wait, seconds}` once it is spent.
  """
  @spec check(String.t()) :: {:ok, non_neg_integer()} | {:wait, pos_integer()}
  def check(wallet) when is_binary(wallet) do
    quota = payments_per_minute()

    case hit(String.downcase(wallet), @window, quota) do
      {:allow, count} -> {:ok, quota - count}
      {:deny, wait} -> {:wait, RateLimitHeaders.seconds(wait)}
    end
  end

  @doc "The standard rate-limit headers for the wallet's \"payments\" share."
  @spec add_headers(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def add_headers(conn, left),
    do: RateLimitHeaders.add(conn, "payments", payments_per_minute(), @window, left)

  @doc "The refusal every door answers with, naming the seconds until the share is whole again."
  @spec refusal(pos_integer()) :: map()
  def refusal(seconds),
    do: %{error: @error, problem_code: "rate_limited", retry_after_seconds: seconds}

  defp payments_per_minute do
    Application.get_env(:patchbay, :payments_per_minute, @default_payments_per_minute)
  end
end
