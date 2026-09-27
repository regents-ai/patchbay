defmodule PatchbayWeb.RateLimitHeaders do
  @moduledoc """
  The standard rate-limit headers, as the IETF describes them
  (draft-ietf-httpapi-ratelimit-headers): `RateLimit-Policy` names a share,
  how many requests it holds and its window in seconds; `RateLimit` says how
  many are left and the seconds until the share is whole again.

  The reads and payments shares are fixed windows on the wall clock, the
  clock Hammer counts them by, so each is whole again when its window ends.
  The hourly posting shares roll, so they say when they are whole again
  themselves. A request drawn on two shares (a payment read is a read too)
  lists both.
  """

  import Plug.Conn

  @doc "Adds the share, its size and window, what is left of it and when it is whole again."
  @spec add(Plug.Conn.t(), String.t(), pos_integer(), pos_integer(), non_neg_integer()) ::
          Plug.Conn.t()
  def add(conn, name, quota, window, remaining),
    do: add(conn, name, quota, window, remaining, seconds_left(window))

  @doc """
  The same for a share whose window rolls, which says itself how many
  seconds until it is whole again.
  """
  @spec add(
          Plug.Conn.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Plug.Conn.t()
  def add(conn, name, quota, window, remaining, whole_in_seconds) do
    conn
    |> append("ratelimit-policy", ~s("#{name}";q=#{quota};w=#{div(window, 1000)}))
    |> append("ratelimit", ~s("#{name}";r=#{remaining};t=#{whole_in_seconds}))
  end

  @doc "Whole seconds, rounded up, so a caller who waits them is never early."
  @spec seconds(non_neg_integer()) :: pos_integer()
  def seconds(milliseconds), do: milliseconds |> Kernel./(1000) |> ceil() |> max(1)

  defp append(conn, header, item) do
    put_resp_header(conn, header, Enum.join(get_resp_header(conn, header) ++ [item], ", "))
  end

  defp seconds_left(window), do: seconds(window - rem(System.system_time(:millisecond), window))
end
