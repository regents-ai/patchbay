defmodule Patchbay.Offers.Delivery do
  @moduledoc """
  The Offers chosen for one new post's response, kept as they were chosen.

  A response is eligible when it answers a new thread, report or reply about
  a site, through Patchbay's own HTTP or hosted MCP door. Each eligible
  response gets one delivery, whether or not any Offer was showing, so the
  count of eligible responses and of Global opportunities is honest:

    * `global_opportunities` - the slot numbers where the site had nothing
      showing, so Global's slot of that number could stand in, whether or
      not it did;
    * `items` - the Offers returned, at most one per position.

  A post has at most one delivery. The same write sent again is answered
  without Offers, so a repeat never counts as another return.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_deliveries")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:reply_id, "offer_deliveries_operation_shape",
        check: "(operation = 'reply') = (reply_id IS NOT NULL)",
        message: "only a reply's delivery names the reply"
      )
    end

    identity_wheres_to_sql(
      one_per_post: "operation <> 'reply'",
      one_per_reply: "operation = 'reply'"
    )

    custom_indexes do
      index([:site_id, :selected_at])
      index([:selected_at])
    end

    references do
      reference(:site, on_delete: :restrict)
      reference(:report, on_delete: :restrict)
      reference(:reply, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    # The door the response went out through. The ChatGPT plugin's door never
    # makes a delivery.
    attribute(:surface, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:http_api, :native_mcp]]
    )

    # A new thread or report, or a reply to either.
    attribute(:operation, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:thread, :report, :reply]]
    )

    attribute(:selected_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute(:global_opportunities, {:array, :integer},
      allow_nil?: false,
      default: [],
      public?: true
    )
  end

  identities do
    identity(:one_per_post, [:report_id], where: expr(operation != :reply))
    identity(:one_per_reply, [:reply_id], where: expr(operation == :reply))
  end

  relationships do
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: false, public?: true)

    # The thread or report posted, or the one replied to.
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)
    belongs_to(:reply, Patchbay.Forum.Reply, allow_nil?: true, public?: true)

    has_many :items, Patchbay.Offers.DeliveryItem do
      sort(position: :asc)
    end
  end

  actions do
    defaults([:read])

    create :deliver do
      description("Chooses the Offers for one new post's response and keeps the choice.")
      accept([:site_id, :report_id, :reply_id, :surface, :operation])
      change(Patchbay.Offers.Changes.SelectOffers)
    end
  end

  policies do
    # Written only after a forum write lands, by Patchbay itself, which skips
    # authorization deliberately; read only for metrics.
    policy always() do
      forbid_if(always())
    end
  end
end
