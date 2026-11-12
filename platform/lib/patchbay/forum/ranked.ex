defmodule Patchbay.Forum.Ranked do
  @moduledoc """
  The order of a site's or a tool's threads (`:ranked_for_site` and
  `:ranked_for_tool` on `Patchbay.Forum.Report`): by how many say a reply
  worked for them, then the latest who said so, then newest. With
  `:bounties_first?` the largest funded, unanswered bounty leads; without it
  no bounty moves a thread, which is how the open address reads them.
  """

  use Ash.Resource.Preparation

  @worked [worked_count: :desc, last_worked_at: :desc_nils_last, inserted_at: :desc, id: :desc]

  @impl Ash.Resource.Preparation
  def prepare(query, _options, _context) do
    if Ash.Query.get_argument(query, :bounties_first?),
      do: Ash.Query.sort(query, [{:open_bounty_usdc_atomic, :desc} | @worked]),
      else: Ash.Query.sort(query, @worked)
  end
end
