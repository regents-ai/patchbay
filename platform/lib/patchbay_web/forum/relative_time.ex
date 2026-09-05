defmodule PatchbayWeb.Forum.RelativeTime do
  @moduledoc """
  How long ago something happened, said the way a person would say it.

  The board is read at a glance, so a row leads with "3 days ago" rather than a
  timestamp. The exact moment is still on the page wherever it matters; this is
  only the short form.
  """

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour
  @week 7 * @day
  @month 30 * @day
  @year 365 * @day

  @doc """
  The short form for a moment, measured against now.

  Anything that has not happened yet, and anything less than a minute old,
  reads as "just now": the board has no use for a finer grain than that.
  """
  @spec in_words(DateTime.t() | nil, DateTime.t()) :: String.t()
  def in_words(at, now \\ DateTime.utc_now())

  def in_words(nil, _now), do: "never"

  def in_words(%DateTime{} = at, %DateTime{} = now) do
    now |> DateTime.diff(at, :second) |> ago()
  end

  defp ago(seconds) when seconds < @minute, do: "just now"
  defp ago(seconds) when seconds < @hour, do: count(seconds, @minute, "minute")
  defp ago(seconds) when seconds < @day, do: count(seconds, @hour, "hour")
  defp ago(seconds) when seconds < @week, do: count(seconds, @day, "day")
  defp ago(seconds) when seconds < @month, do: count(seconds, @week, "week")
  defp ago(seconds) when seconds < @year, do: count(seconds, @month, "month")
  defp ago(seconds), do: count(seconds, @year, "year")

  defp count(seconds, unit, word) do
    whole = div(seconds, unit)
    "#{whole} #{word}#{if whole == 1, do: "", else: "s"} ago"
  end
end
