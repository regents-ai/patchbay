defmodule PatchbayWeb.CreditsLimit do
  @moduledoc """
  The Buy Credits panel's allowances for each signed-in profile, as in the
  Regent template: 30 wallet readings a minute (its USDC and approval on Base)
  and 120 purchase reports a minute. It lives in this node's memory, which is
  the whole of Patchbay: the site runs on one machine.
  """

  use Hammer, backend: :ets

  @allowances %{wallet_read: 30, credits_report: 120}
  @window :timer.minutes(1)

  @doc "Spends one of `name`'s allowance for the profile: `:ok` or `:limited`."
  @spec spend(:wallet_read | :credits_report, String.t()) :: :ok | :limited
  def spend(name, profile_id) do
    case hit("#{name}:#{profile_id}", @window, Map.fetch!(@allowances, name)) do
      {:allow, _count} -> :ok
      {:deny, _wait} -> :limited
    end
  end
end
