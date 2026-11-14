defmodule Patchbay.Offers.Eligibility do
  @moduledoc """
  Whether a campaign may run in a placement. Both sides must agree, and
  anything missing counts against it:

    * the campaign runs on the placement's site: every listed site, the sites
      it names, or the kind of site it names;
    * Patchbay accepts its advertiser's wallet and has not blocked it (a
      blocked wallet stays blocked even if it is also accepted);
    * the placement was created under Patchbay's current admission policy.
  """

  alias Patchbay.Offers

  @type reason :: :unknown_site | :not_on_site | :not_accepted | :blocked | :other_policy

  @doc """
  `:ok`, or the first reason the campaign may not run in the placement.
  `rules` are Patchbay's rules on the advertiser's wallet, and `site_kind` is
  the kind of site the placement is on, when it is listed.
  """
  @spec check(map(), map(), [map()], atom() | nil) :: :ok | {:error, reason()}
  def check(campaign, placement, rules, site_kind) do
    with :ok <- policy(placement),
         :ok <- runs_on(campaign, placement, site_kind),
         do: accepted(campaign.advertiser, rules)
  end

  defp policy(placement) do
    if placement.policy_hash == Offers.policy_hash(), do: :ok, else: {:error, :other_policy}
  end

  defp runs_on(_campaign, %{source_origin: nil}, _kind), do: {:error, :unknown_site}
  defp runs_on(%{audience: :all}, _placement, _kind), do: :ok

  defp runs_on(%{audience: :sites, sites: sites}, %{source_origin: origin}, _kind),
    do: if(origin in sites, do: :ok, else: {:error, :not_on_site})

  defp runs_on(%{audience: :group, group: group}, _placement, kind),
    do: if(kind != nil and kind == group, do: :ok, else: {:error, :not_on_site})

  defp accepted(wallet, rules) do
    verdicts = for %{wallet: ^wallet, verdict: verdict} <- rules, do: verdict

    cond do
      :blocked in verdicts -> {:error, :blocked}
      :accepted in verdicts -> :ok
      true -> {:error, :not_accepted}
    end
  end
end
