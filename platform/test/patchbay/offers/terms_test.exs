defmodule Patchbay.Offers.TermsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Patchbay.Offers.{Terms, UsdcAmount}

  doctest Terms
  doctest UsdcAmount

  @start ~U[2026-10-05 18:00:00.000000Z]

  describe "amounts" do
    test "decimal strings with at most two fractional digits become minor units" do
      assert UsdcAmount.parse("1") == {:ok, 100}
      assert UsdcAmount.parse("1.5") == {:ok, 150}
      assert UsdcAmount.parse("1.05") == {:ok, 105}
      assert UsdcAmount.parse("0.99") == {:ok, 99}
    end

    test "signs, exponents, extra precision, spaces and floats are refused" do
      for text <- ["-1", "+1", "1e2", "1.001", " 1", "1 ", ".5", "1.", "NaN", "Infinity", ""] do
        assert UsdcAmount.parse(text) == :error, text
      end

      assert UsdcAmount.parse(1.0) == :error
      assert UsdcAmount.parse(100) == :error
    end

    test "more than fifteen whole digits is refused" do
      assert {:ok, max} = UsdcAmount.parse("999999999999999.99")
      assert max == UsdcAmount.max_minor()
      assert UsdcAmount.parse("1000000000000000") == :error
    end

    property "formatting and parsing agree" do
      check all(minor <- integer(0..UsdcAmount.max_minor())) do
        assert UsdcAmount.parse(UsdcAmount.format(minor)) == {:ok, minor}
      end
    end
  end

  describe "the replacement minimum" do
    test "is ten percent more, rounded up to the hundredth" do
      assert Terms.replacement_minimum(1001, 100) == 1102
      assert Terms.replacement_minimum(11_500, 100) == 12_650
      assert Terms.replacement_minimum(10_000, 100) == 11_000
    end

    test "is never under the opening minimum" do
      assert Terms.replacement_minimum(100, 500) == 500
    end

    property "is the smallest hundredth at or above 110 percent" do
      check all(bid <- integer(1..100_000_000), minimum <- integer(1..1_000)) do
        least = Terms.replacement_minimum(bid, minimum)
        assert least >= minimum

        if least > minimum do
          assert least * 10 >= bid * 11
          assert (least - 1) * 10 < bid * 11
        end
      end
    end
  end

  describe "how a placement's USDC divides" do
    test "a 30-USDC placement bought out after 24 hours returns 20" do
      expires = Terms.expires_at(@start)
      at = DateTime.add(@start, 24, :hour)

      assert Terms.bought_out(3000, expires, at) == %{
               returned: 2000,
               consumed: 1000,
               forfeited: 0
             }
    end

    test "a 1.01-USDC placement bought out after ten minutes returns 1.00" do
      expires = Terms.expires_at(@start)

      assert Terms.bought_out(101, expires, DateTime.add(@start, 10, :minute)).returned == 100
    end

    test "nothing is returned at or after expiry" do
      expires = Terms.expires_at(@start)

      assert Terms.unused(3000, expires, expires) == 0
      assert Terms.unused(3000, expires, DateTime.add(expires, 1, :second)) == 0
    end

    test "a removal returns nothing and forfeits the unused share" do
      expires = Terms.expires_at(@start)
      at = DateTime.add(@start, 24, :hour)

      assert Terms.removed(3000, expires, at) == %{returned: 0, consumed: 1000, forfeited: 2000}
    end

    test "a placement is exactly 259,200 seconds, across a daylight-saving change too" do
      starts = ~U[2026-10-24 12:00:00.000000Z]

      assert DateTime.diff(Terms.expires_at(starts), starts, :second) == 259_200
    end

    property "every split conserves the original bid and never returns more than it" do
      check all(
              bid <- integer(1..UsdcAmount.max_minor()),
              elapsed <- integer(-1_000_000..(Terms.duration_us() + 1_000_000))
            ) do
        expires = Terms.expires_at(@start)
        at = DateTime.add(@start, elapsed, :microsecond)

        for split <- [
              Terms.bought_out(bid, expires, at),
              Terms.removed(bid, expires, at),
              Terms.expired(bid)
            ] do
          assert split.returned + split.consumed + split.forfeited == bid
          assert split.returned <= bid
          assert Enum.all?(Map.values(split), &(&1 >= 0))
        end
      end
    end
  end
end
