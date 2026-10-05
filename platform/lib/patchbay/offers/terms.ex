defmodule Patchbay.Offers.Terms do
  @moduledoc """
  The arithmetic of a placement: its 72 hours, the price that replaces it,
  and how its USDC divides when it ends.

  Every amount is in minor units (one cent of USDC) and every time
  is a UTC `DateTime` to the microsecond. A placement runs on the half-open
  interval `starts_at <= time < expires_at`, exactly 259,200 seconds long.

  When a placement ends, its original bid divides into what goes back to the
  owner, what was used for time, and what was forfeited:

      original = returned + consumed + forfeited

  The refund is computed once and the consumed amount is the remainder, so
  the two are never rounded independently.
  """

  @duration_us 259_200_000_000

  @typedoc "How a terminal placement's original bid divides."
  @type split :: %{
          returned: non_neg_integer(),
          consumed: non_neg_integer(),
          forfeited: non_neg_integer()
        }

  @doc "A placement's length in microseconds."
  @spec duration_us() :: pos_integer()
  def duration_us, do: @duration_us

  @doc "When a placement that starts at `starts_at` expires."
  @spec expires_at(DateTime.t()) :: DateTime.t()
  def expires_at(%DateTime{} = starts_at),
    do: DateTime.add(starts_at, @duration_us, :microsecond)

  @doc """
  The least a bid may be to replace `current_minor`: ten percent more,
  rounded up to the next hundredth, and never under the opening minimum.

      iex> Patchbay.Offers.Terms.replacement_minimum(1001, 100)
      1102
  """
  @spec replacement_minimum(pos_integer(), pos_integer()) :: pos_integer()
  def replacement_minimum(current_minor, opening_minimum_minor)
      when is_integer(current_minor) and current_minor > 0 and
             is_integer(opening_minimum_minor) and opening_minimum_minor > 0 do
    max(opening_minimum_minor, div(current_minor * 11 + 9, 10))
  end

  @doc """
  The unused share of `bid_minor` at `at` for a placement ending at
  `expires_at`, rounded down to the hundredth. Nothing at or after expiry.

      iex> starts = ~U[2026-10-05 00:00:00.000000Z]
      iex> Patchbay.Offers.Terms.unused(3000, Patchbay.Offers.Terms.expires_at(starts), DateTime.add(starts, 24, :hour))
      2000
  """
  @spec unused(pos_integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def unused(bid_minor, %DateTime{} = expires_at, %DateTime{} = at) do
    remaining_us =
      expires_at
      |> DateTime.diff(at, :microsecond)
      |> max(0)
      |> min(@duration_us)

    div(bid_minor * remaining_us, @duration_us)
  end

  @doc "A placement bought out at `at`: the unused share goes back to its owner."
  @spec bought_out(pos_integer(), DateTime.t(), DateTime.t()) :: split()
  def bought_out(bid_minor, expires_at, at) do
    returned = unused(bid_minor, expires_at, at)
    %{returned: returned, consumed: bid_minor - returned, forfeited: 0}
  end

  @doc "A placement that ran its full time: all of it was used."
  @spec expired(pos_integer()) :: split()
  def expired(bid_minor), do: %{returned: 0, consumed: bid_minor, forfeited: 0}

  @doc """
  A placement a moderator removed at `at`: nothing goes back, the unused
  share is forfeited, and the rest was used for time.
  """
  @spec removed(pos_integer(), DateTime.t(), DateTime.t()) :: split()
  def removed(bid_minor, expires_at, at) do
    forfeited = unused(bid_minor, expires_at, at)
    %{returned: 0, consumed: bid_minor - forfeited, forfeited: forfeited}
  end
end
