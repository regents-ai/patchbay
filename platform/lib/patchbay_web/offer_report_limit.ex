defmodule PatchbayWeb.OfferReportLimit do
  @moduledoc """
  Gives each reporter ten Offer reports an hour, counted by the signed-in
  profile or forum session the report is filed under. A new session costs
  nothing, so a report with nobody signed in is also counted against the
  address it came from (`PatchbayWeb.ClientAddress.visitor_key/1`), which has
  the same hourly share, as forum posts are. Reporting the same Offer again
  answers with the first report but still draws on the share, so a loop of
  repeats is slowed too. It lives in this node's memory, which is the whole of
  Patchbay: the site runs on one machine.
  """

  use Hammer, backend: :ets

  @reports_per_hour 10
  @window :timer.hours(1)

  @doc """
  Draws one report on the reporter's share, and on its address's share when
  nobody is signed in: `:ok`, or the refusal the forum doors answer with once
  either is spent.
  """
  @spec check(String.t(), :account | :session, String.t()) ::
          :ok
          | {:error, {:rate_limited, :account | :session | :address, String.t(), pos_integer()}}
  def check(reporter, :account, _visitor) when is_binary(reporter), do: draw(reporter, :account)

  def check(reporter, :session, visitor) when is_binary(reporter) and is_binary(visitor) do
    with :ok <- draw(reporter, :session), do: draw("address:" <> visitor, :address)
  end

  defp draw(key, counted) do
    case hit(key, @window, @reports_per_hour) do
      {:allow, _count} ->
        :ok

      {:deny, wait} ->
        {:error,
         {:rate_limited, counted, "Ten Offer reports an hour is the most one reporter can send.",
          PatchbayWeb.RateLimitHeaders.seconds(wait)}}
    end
  end
end
