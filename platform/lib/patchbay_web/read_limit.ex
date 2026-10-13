defmodule PatchbayWeb.ReadLimit do
  @moduledoc """
  The counter behind `PatchbayWeb.Plugs.ReadBudget` and
  `PatchbayWeb.Plugs.SignedBudget`. It lives in this node's memory, which is
  the whole of Patchbay: the site runs on one machine.
  """
  use Hammer, backend: :ets

  alias PatchbayWeb.RateLimitHeaders

  @doc """
  Counts one request against `key`'s share and says where the share stands,
  in the shape `RegentAgentAccess.RateLimit` asks of a site's counter.
  """
  @spec admit(term(), pos_integer(), pos_integer()) ::
          {:ok, RegentAgentAccess.RateLimit.budget()}
          | {:error, :rate_limited, RegentAgentAccess.RateLimit.budget()}
  def admit(key, limit, window_seconds) do
    window = :timer.seconds(window_seconds)

    case hit(key, window, limit) do
      {:allow, count} ->
        {:ok, budget(limit, limit - count, RateLimitHeaders.seconds_left(window), window_seconds)}

      {:deny, wait} ->
        {:error, :rate_limited, budget(limit, 0, RateLimitHeaders.seconds(wait), window_seconds)}
    end
  end

  defp budget(limit, remaining, reset, window),
    do: %{limit: limit, remaining: remaining, reset: reset, window: window}
end
