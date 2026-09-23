defmodule PatchbayWeb.FixCheckLimitTest do
  @moduledoc """
  Addresses without tools are counted over the last hour, each one once,
  and the one that makes it more than three starts a wait of a full hour
  from that moment.
  """

  use ExUnit.Case, async: false

  alias PatchbayWeb.FixCheckLimit

  @minute :timer.minutes(1)

  test "misses count over the last hour, and the fourth starts a full hour's wait" do
    visitor = "visitor-#{System.unique_integer([:positive])}"
    start = System.system_time(:millisecond)
    at = fn minutes -> start + minutes * @minute end

    assert {:ok, 1} = FixCheckLimit.missed(visitor, "https://a.example.com/", at.(0))
    assert {:ok, 1} = FixCheckLimit.missed(visitor, "https://a.example.com/", at.(1))
    assert {:ok, 2} = FixCheckLimit.missed(visitor, "https://b.example.com/", at.(10))
    assert {:ok, 3} = FixCheckLimit.missed(visitor, "https://c.example.com/", at.(20))

    # An hour on, the first has lapsed: a fourth address is only the third in the hour.
    assert {:ok, 3} = FixCheckLimit.missed(visitor, "https://d.example.com/", at.(61))
    assert :ok = FixCheckLimit.draw(visitor, at.(61))

    # The fourth in the hour starts a wait of a full hour from that moment.
    assert {:wait, 3600} = FixCheckLimit.missed(visitor, "https://e.example.com/", at.(62))
    assert {:wait, 1800} = FixCheckLimit.draw(visitor, at.(92))
    assert {:wait, 60} = FixCheckLimit.draw(visitor, at.(121))
    assert :ok = FixCheckLimit.draw(visitor, at.(122))
    assert FixCheckLimit.misses(visitor, at.(122)) == 0
  end

  test "thirty checks in ten minutes, then a wait until the ten minutes are up" do
    visitor = "visitor-#{System.unique_integer([:positive])}"
    window = :timer.minutes(10)
    start = div(System.system_time(:millisecond), window) * window + window

    for _check <- 1..30, do: assert(:ok = FixCheckLimit.draw(visitor, start))
    assert {:wait, 540} = FixCheckLimit.draw(visitor, start + @minute)
    assert :ok = FixCheckLimit.draw(visitor, start + window)
  end

  test "the sweep drops lapsed rows and keeps live ones" do
    visitor = "visitor-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)
    long_ago = now - :timer.hours(2)

    FixCheckLimit.missed(visitor, "https://old.example.com/", long_ago)
    FixCheckLimit.missed(visitor, "https://new.example.com/", now)
    FixCheckLimit.draw(visitor, long_ago)

    limit = Process.whereis(FixCheckLimit)
    send(limit, :sweep)
    :sys.get_state(limit)

    assert Process.whereis(FixCheckLimit) == limit

    assert :ets.match(FixCheckLimit, {{:missed, visitor, :"$1"}, :_}) == [
             ["https://new.example.com/"]
           ]

    assert :ets.match(FixCheckLimit, {{:checks, visitor, :_}, :_, :_}) == []
  end
end
