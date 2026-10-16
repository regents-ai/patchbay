defmodule Patchbay.Offers do
  @moduledoc """
  Agent Offers: clearly labelled third-party advertisements that follow a
  successful new thread or reply on Patchbay.

  Each site board has a market of three numbered slots, and one Global
  market of three more stands in for any site slot that is empty. An
  advertiser saves a short Offer, Patchbay screens it, and a placement in a
  slot runs for up to 72 hours. Prices are in Credits. Each bid's Credits
  are held in the shared Credits ledger (`Patchbay.Offers.Holds`) until it
  settles; this domain keeps the market and never a balance.

  The organic board is never changed by an Offer: replies, solved answers
  and their order stay as they are, and Offers are only ever added after a
  forum result, in their own section.
  """

  use Ash.Domain, otp_app: :patchbay

  import Ash.Expr, only: [expr: 1]

  @active_page 50
  @history_page 20
  @offer [version: [:creative, :blocked_at], slot: [market: :site]]

  @doc "Whether automatic screening is paused for this local preview."
  def screening_paused? do
    :patchbay |> Application.get_env(Oban, []) |> Keyword.get(:testing) == :manual
  end

  @doc """
  How long a screening's allow counts, in microseconds, before the version
  must be screened again to be shown or promoted. 24 hours unless set in
  `config :patchbay, :offers, approval_fresh_for_us:`.
  """
  @spec approval_fresh_for_us() :: pos_integer()
  def approval_fresh_for_us do
    :patchbay
    |> Application.get_env(:offers, [])
    |> Keyword.get(:approval_fresh_for_us, 86_400_000_000)
  end

  @doc """
  The global opening minimum in minor units: 1.00 Credit unless set in
  `config :patchbay, :offers, default_minimum_minor:`.
  """
  @spec default_minimum_minor() :: pos_integer()
  def default_minimum_minor do
    :patchbay
    |> Application.get_env(:offers, [])
    |> Keyword.get(:default_minimum_minor, 100)
  end

  @doc """
  The opening minimum of a market in minor units: the site's own when it
  sets one, otherwise the default. Global, and a site whose market has
  not been opened yet, use the default.
  """
  @spec opening_minimum_minor(Patchbay.Offers.Market.t() | nil) :: pos_integer()
  def opening_minimum_minor(%{minimum_override_minor: minor}) when is_integer(minor), do: minor
  def opening_minimum_minor(_market), do: default_minimum_minor()

  @doc """
  `profile`'s own Offers in progress at `as_of`, as the Active tab shows
  them: the placements `showing` now, the bids `leading` for a slot's next
  period (each slot with its running placement, which says when that period
  starts), and the bids `waiting` in an open window for their result. At
  most #{@active_page} of each, newest first.

  Every list is read through its record's `:mine` read with `profile` as the
  actor, so it holds only `profile`'s own.
  """
  @spec my_active(Patchbay.Identity.AgentProfile.t(), DateTime.t()) :: %{
          showing: [Patchbay.Offers.Placement.t()],
          leading: [Patchbay.Offers.Bid.t()],
          waiting: [Patchbay.Offers.Bid.t()]
        }
  def my_active(profile, as_of) do
    page = [limit: @active_page]

    %{
      showing:
        my_placements!(
          actor: profile,
          query: [filter: expr(status == :active and expires_at > ^as_of), load: @offer],
          page: page
        ).results,
      leading:
        my_bids!(
          actor: profile,
          query: [
            filter: expr(status == :leading),
            load: [version: [:creative, :blocked_at], slot: [:active_placement, market: :site]]
          ],
          page: page
        ).results,
      waiting:
        my_bids!(
          actor: profile,
          query: [filter: expr(status == :held), load: @offer],
          page: page
        ).results
    }
  end

  @doc """
  One page of `profile`'s own past Offers, newest first, as the History tab
  lists them: `:ended`, the placements that have ended, or `:lost_bids`, the
  bids that did not win and came back in full. `after` is the keyset the
  previous page of the same list ended on, or nil for the newest. At most
  #{@history_page} a page.

  Read through the record's `:mine` read with `profile` as the actor, so it
  holds only `profile`'s own.
  """
  @spec my_history(Patchbay.Identity.AgentProfile.t(), :ended | :lost_bids, String.t() | nil) ::
          Ash.Page.Keyset.t()
  def my_history(profile, :ended, after_keyset) do
    my_placements!(
      actor: profile,
      query: [filter: expr(status != :active), load: @offer],
      page: history_page(after_keyset)
    )
  end

  def my_history(profile, :lost_bids, after_keyset) do
    my_bids!(
      actor: profile,
      query: [filter: expr(status == :returned), load: @offer],
      page: history_page(after_keyset)
    )
  end

  defp history_page(nil), do: [limit: @history_page]
  defp history_page(keyset), do: [limit: @history_page, after: keyset]

  resources do
    resource Patchbay.Offers.Market do
      define(:get_market, action: :read, get_by: [:id])
      define(:global_market, action: :global)
      define(:open_site_market, action: :open_for_site, args: [:site_id])
    end

    resource(Patchbay.Offers.Slot)

    resource Patchbay.Offers.Creative do
      define(:create_creative, action: :save, args: [:label, :text, :request_key])
      define(:archive_creative, action: :archive)
      define(:delete_creative, action: :delete)
      define(:my_creatives, action: :mine)
    end

    resource Patchbay.Offers.CreativeVersion do
      define(:save_creative_version, action: :save, args: [:creative_id, :text, :request_key])
      define(:get_creative_version, action: :read, get_by: [:id])
    end

    resource Patchbay.Offers.OfferText do
      define(:block_words, action: :block, args: [:version_id, :reason, :idempotency_key])
    end

    resource(Patchbay.Offers.DailySave)
    resource(Patchbay.Offers.TurnDown)

    resource Patchbay.Offers.Review do
      define(:request_market_review, action: :request_relevance, args: [:version_id, :market_id])
    end

    resource(Patchbay.Offers.BidWindow)

    resource Patchbay.Offers.Bid do
      define(:submit_bid, action: :submit)
      define(:my_bids, action: :mine)
    end

    resource Patchbay.Offers.Placement do
      define(:my_placements, action: :mine)
    end

    resource Patchbay.Offers.ModerationAction do
      define(:remove_placement, action: :remove_placement)
    end

    resource(Patchbay.Offers.Delivery)
    resource(Patchbay.Offers.DeliveryItem)

    resource Patchbay.Offers.OfferReport do
      define(:file_offer_report, action: :file, args: [:reporter, :surface])
    end
  end
end
