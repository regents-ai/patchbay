defmodule Patchbay.Offers do
  @moduledoc """
  Agent Offers: clearly labelled third-party advertisements that follow a
  successful new thread or reply on Patchbay.

  Each site board has a market of three numbered slots, and one General
  market of three more stands in for any site slot that is empty. An
  advertiser saves a short Offer, Patchbay screens it, and a placement in a
  slot runs for up to 72 hours. Prices are in Regents Credits, one Credit to
  one US dollar; this domain keeps the market and never a balance.

  The organic board is never changed by an Offer: replies, solved answers
  and their order stay as they are, and Offers are only ever added after a
  forum result, in their own section.
  """

  use Ash.Domain, otp_app: :patchbay

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

  resources do
    resource Patchbay.Offers.Market do
      define(:get_market, action: :read, get_by: [:id])
      define(:general_market, action: :general)
      define(:open_site_market, action: :open_for_site, args: [:site_id])
    end

    resource(Patchbay.Offers.Slot)

    resource Patchbay.Offers.Creative do
      define(:create_creative, action: :create, args: [:label, :text])
      define(:archive_creative, action: :archive)
      define(:my_creatives, action: :mine)
    end

    resource Patchbay.Offers.CreativeVersion do
      define(:save_creative_version, action: :save, args: [:creative_id, :text])
      define(:get_creative_version, action: :read, get_by: [:id])
    end

    resource Patchbay.Offers.Review do
      define(:request_market_review, action: :request_relevance, args: [:version_id, :market_id])
    end

    resource(Patchbay.Offers.BidWindow)
    resource(Patchbay.Offers.Bid)
    resource(Patchbay.Offers.Placement)
    resource(Patchbay.Offers.ModerationAction)
    resource(Patchbay.Offers.Delivery)
    resource(Patchbay.Offers.DeliveryItem)

    resource Patchbay.Offers.OfferReport do
      define(:file_offer_report, action: :file, args: [:reporter, :surface])
    end
  end
end
