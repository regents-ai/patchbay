defmodule Patchbay.Offers.Eligibility do
  @moduledoc """
  Whether a campaign may run, from both sides, with anything missing counting
  against it.

  Where (`check/3`), for buying a slot and for showing a lease:

    * the placement was created under Patchbay's current admission policy;
    * the campaign runs on the placement's site: every listed site, the sites
      it names, or the kind of site it names;
    * Patchbay accepts its advertiser's wallet and has not blocked it (a
      blocked wallet stays blocked even if it is also accepted, and even in a
      pool that names it);
    * it is in one of the pools Patchbay chose for the placement, or the
      placement has none chosen and shows from General, every campaign
      Patchbay accepts (`Patchbay.Offers.Pool`);
    * Patchbay approved it and has not pulled it (`Patchbay.Offers.Review`).

  To whom (`qualifies/3`), each time it would be shown, by what the campaign
  sealed:

    * the question it goes with carries one of its topic tags, and is one of
      its kinds of thread, when it names any;
    * the reader proved what it requires: `:paired` is a signed agent paired
      with a Regent account, and a reader that proved nothing proved none;
    * the reader's wallet is not one it excludes. A reader whose wallet is
      not known is on no list; a campaign that must be sure requires
      `:paired`.

  How often one reader sees it in a day is kept where deliveries are written
  (`Patchbay.Offers.Serving`).
  """

  alias Patchbay.Offers

  @system %{role: :system}

  @type reason ::
          :other_policy
          | :unknown_site
          | :not_on_site
          | :blocked
          | :not_accepted
          | :not_in_pool
          | :not_approved
          | :pulled

  @type unqualified :: :not_for_task | :missing_evidence | :excluded

  @typedoc "Patchbay's side of `check/3`, as `terms/2` reads it."
  @type terms :: %{
          rules: [map()],
          pools: %{pos_integer() => [map()]},
          site_kinds: %{String.t() => atom()}
        }

  @typedoc "What an answer is about: its question's topic tags and kind of thread."
  @type task :: %{tags: [String.t()], kind: atom() | nil}

  @typedoc "What Patchbay knows of the reader: its wallet and what it proved."
  @type reader :: %{wallet: String.t() | nil, evidence: [atom()]}

  @doc """
  Patchbay's own side, read as the system for `placements` and `campaigns`:
  its rules on their advertisers' wallets, the pools chosen for each
  placement with their members, and the kind of each placement's site where
  a campaign runs on one kind.
  """
  @spec terms([map()], [map()]) :: terms()
  def terms(placements, campaigns) do
    %{chain_id: chain_id} = Offers.chain()
    advertisers = campaigns |> Enum.map(& &1.advertiser) |> Enum.uniq()

    pools =
      chain_id
      |> Offers.placement_pools!(Offers.market(), Enum.map(placements, & &1.placement_id),
        actor: @system,
        load: [pool: [:members]]
      )
      |> Enum.group_by(& &1.placement_id, & &1.pool)

    %{
      rules: Offers.advertiser_rules!(advertisers, actor: @system),
      pools: pools,
      site_kinds: site_kinds(placements, campaigns)
    }
  end

  @doc """
  `:ok`, or the first reason `campaign` may not run in `placement` under
  `terms`. The campaign carries its `review`.
  """
  @spec check(map(), map(), terms()) :: :ok | {:error, reason()}
  def check(campaign, placement, terms) do
    with :ok <- policy(placement),
         :ok <- runs_on(campaign, placement, terms.site_kinds[placement.source_origin]),
         :ok <- accepted(campaign.advertiser, terms.rules),
         :ok <- pooled(campaign, Map.get(terms.pools, placement.placement_id, [])),
         do: reviewed(campaign.review)
  end

  @doc "`:ok`, or why `campaign` is not for `reader` on an answer about `task`."
  @spec qualifies(map(), task(), reader()) :: :ok | {:error, unqualified()}
  def qualifies(campaign, task, reader) do
    cond do
      campaign.tags != [] and not Enum.any?(task.tags, &(&1 in campaign.tags)) ->
        {:error, :not_for_task}

      campaign.kinds != [] and task.kind not in campaign.kinds ->
        {:error, :not_for_task}

      not Enum.all?(campaign.requires, &(&1 in reader.evidence)) ->
        {:error, :missing_evidence}

      reader.wallet != nil and reader.wallet in campaign.excluded_wallets ->
        {:error, :excluded}

      true ->
        :ok
    end
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

  defp pooled(_campaign, []), do: :ok

  defp pooled(campaign, pools) do
    if Enum.any?(pools, &in_pool?(campaign, &1)), do: :ok, else: {:error, :not_in_pool}
  end

  @doc "Whether `campaign` is in `pool`, whose members are loaded."
  @spec in_pool?(map(), map()) :: boolean()
  def in_pool?(campaign, pool) do
    (pool.tags == [] or Enum.any?(campaign.tags, &(&1 in pool.tags))) and
      (pool.members == [] or Enum.any?(pool.members, &(&1.wallet == campaign.advertiser)))
  end

  defp reviewed(:approved), do: :ok
  defp reviewed(:pulled), do: {:error, :pulled}
  defp reviewed(:waiting), do: {:error, :not_approved}

  # The kind of site is read only for a campaign that runs on one kind.
  defp site_kinds(placements, campaigns) do
    if Enum.any?(campaigns, &(&1.audience == :group)) do
      for %{source_origin: origin} when is_binary(origin) <- placements,
          {:ok, %{entity_type: kind}} <-
            [Patchbay.Forum.get_site_by_origin(origin, not_found_error?: false)],
          into: %{},
          do: {origin, kind}
    else
      %{}
    end
  end
end
