defmodule PatchbayWeb.OfferReportLimit do
  @moduledoc """
  Gives each reporter ten Offer reports an hour, counted by the person the
  report is filed for: only a signed, paired agent reports an Offer.
  Reporting the same Offer again answers with the first report but still
  draws on the share, so a loop of repeats is slowed too. It lives in this
  node's memory, which is the whole of Patchbay: the site runs on one machine.
  """

  use Hammer, backend: :ets

  @reports_per_hour 10
  @window :timer.hours(1)

  @doc """
  Draws one report on the reporter's share: `:ok`, or the refusal the forum
  doors answer with once it is spent.
  """
  @spec check(String.t()) ::
          :ok | {:error, {:rate_limited, :account, String.t(), pos_integer()}}
  def check(reporter) when is_binary(reporter) do
    case hit(reporter, @window, @reports_per_hour) do
      {:allow, _count} ->
        :ok

      {:deny, wait} ->
        {:error,
         {:rate_limited, :account, "Ten Offer reports an hour is the most one reporter can send.",
          PatchbayWeb.RateLimitHeaders.seconds(wait)}}
    end
  end
end
