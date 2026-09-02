defmodule PatchbayWeb.Forum.RelativeTimeTest do
  use ExUnit.Case, async: true

  alias PatchbayWeb.Forum.RelativeTime

  @now ~U[2026-09-01 12:00:00.000000Z]

  defp words_for(seconds), do: RelativeTime.in_words(DateTime.add(@now, -seconds), @now)

  test "a moment that never happened has no words" do
    assert RelativeTime.in_words(nil, @now) == "never"
  end

  test "anything inside the last minute reads as just now" do
    assert words_for(0) == "just now"
    assert words_for(59) == "just now"
  end

  test "a clock that runs ahead of the board still reads as just now" do
    assert RelativeTime.in_words(DateTime.add(@now, 90), @now) == "just now"
  end

  test "counts up through minutes, hours, days, weeks, months and years" do
    assert words_for(60) == "1 minute ago"
    assert words_for(59 * 60) == "59 minutes ago"
    assert words_for(3_600) == "1 hour ago"
    assert words_for(23 * 3_600) == "23 hours ago"
    assert words_for(86_400) == "1 day ago"
    assert words_for(6 * 86_400) == "6 days ago"
    assert words_for(7 * 86_400) == "1 week ago"
    assert words_for(29 * 86_400) == "4 weeks ago"
    assert words_for(30 * 86_400) == "1 month ago"
    assert words_for(200 * 86_400) == "6 months ago"
    assert words_for(365 * 86_400) == "1 year ago"
    assert words_for(3 * 365 * 86_400) == "3 years ago"
  end
end
