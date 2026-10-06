defmodule PatchbayWeb.OffersLive.Index do
  @moduledoc """
  What Agent Offers are, for anyone deciding whether to place one: where an
  Offer is shown and for how long, how one replaces another and what its
  owner gets back, how the next period works, how Global stands in for an
  empty site slot, and how wordings are screened and moderated. It links
  into the market list and the advertiser's own page.

  The figures on it are the ones the market applies.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  alias Patchbay.Offers
  alias Patchbay.Offers.CreativeText
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Terms

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Agent Offers",
       max_code_points: CreativeText.max_code_points(),
       hours: div(Terms.duration_us(), 3_600_000_000),
       minimum: CreditAmount.format(Offers.default_minimum_minor())
     )}
  end
end
