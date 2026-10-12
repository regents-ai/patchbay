defmodule Patchbay.Offers.Review do
  @moduledoc """
  Patchbay's screening of one Offer wording.

  Every version has one safety review, made when it is saved. A version bid
  into a site market also needs a relevance review for that market; Global
  needs only the safety review. Each row keeps its latest decision and the
  evidence behind it, and is screened again in place when it is asked for
  again or its approval grows stale:

    * `:pending` - not screened yet; the version cannot be bid with;
    * `:allow` - screened and allowed until `fresh_until`;
    * `:deny` - turned down: screening refused it, was not sure, or could
      not run. Every turn-down is logged (`Patchbay.Offers.TurnDown`).

  Nobody decides a review by hand. An allow is screening evidence, never a
  public promise that the Offer is safe. The private reason is never shown
  with an Offer.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban],
    notifiers: [Ash.Notifier.PubSub]

  oban do
    triggers do
      # A screening that fails is tried again with Oban's backoff; after the
      # last try the version is turned down. It runs on its own queue so slow pages
      # never hold up bidding or report reading.
      trigger :screen do
        action(:screen)
        queue(:offers_review)
        where(expr(not is_nil(screen_requested_at)))
        max_attempts(3)
        on_error(:screening_failed)
        lock_for_update?(false)
        worker_module_name(Patchbay.Offers.Review.Workers.Screen)
        scheduler_module_name(Patchbay.Offers.Review.Schedulers.Screen)
      end

      # Copy that is showing, waiting in a window or leading the next period
      # is screened again every six hours, well inside the day an allow
      # counts for, so a promotion never waits on a page being visited.
      trigger :refresh do
        action(:rescreen)
        queue(:offers_review)
        scheduler_cron("*/10 * * * *")

        where(
          expr(
            is_nil(screen_requested_at) and decided_at < ago(6, :hour) and
              (exists(version.placements, status == :active) or
                 exists(version.bids, status in [:held, :leading]))
          )
        )

        max_attempts(3)
        worker_module_name(Patchbay.Offers.Review.Workers.Refresh)
        scheduler_module_name(Patchbay.Offers.Review.Schedulers.Refresh)
      end
    end
  end

  # A decision tells every open Offers page to read again; each reads only
  # what it may see. Advisory: a page that misses one reads on reconnect.
  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:record, ["offers:reviews"], transform: &__MODULE__.changed_message/1)
    publish(:screening_failed, ["offers:reviews"], transform: &__MODULE__.changed_message/1)
  end

  @doc "The PubSub topic a screening decision is announced on."
  @spec topic() :: String.t()
  def topic, do: "offers:reviews"

  @doc false
  def changed_message(_notification), do: :offer_reviews_changed

  postgres do
    table("offer_reviews")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:market_id, "offer_reviews_kind_shape",
        check: "(kind = 'relevance') = (market_id IS NOT NULL)",
        message: "a relevance review names its market and a safety review names none"
      )
    end

    custom_indexes do
      index([:screen_requested_at], where: "screen_requested_at IS NOT NULL")
      index([:fresh_until])
    end

    # One safety review per version, and one relevance review per version and
    # market; each shape has its own partial unique index.
    identity_wheres_to_sql(
      unique_safety: "kind = 'safety'",
      unique_relevance: "kind = 'relevance'"
    )

    references do
      reference(:version, on_delete: :delete)
      reference(:market, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:safety, :relevance]]
    )

    attribute(:decision, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :allow, :deny]]
    )

    # Short fixed codes for the advertiser, such as `link_unreadable`.
    attribute(:reason_codes, {:array, :string}, allow_nil?: false, default: [], public?: true)

    # Admin-only words from the screening; never shown with an Offer.
    attribute(:private_reason, :string, allow_nil?: true, constraints: [max_length: 2000])

    # What screened it: the model and provider, or nil when screening could
    # not run, and the policy the screening followed.
    attribute(:model, :string, allow_nil?: true, public?: true)
    attribute(:policy_version, :string, allow_nil?: true, public?: true)

    # The SHA-256 of what screening read: the text and every fetched page.
    attribute(:input_sha256, :string, allow_nil?: true)

    # Each destination: where it went, every hop, the status and a hash of
    # what came back. Private, and never the page itself.
    attribute(:destinations, {:array, :map}, allow_nil?: false, default: [])

    attribute(:decided_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    # An allow counts until this time; after it the version waits for a
    # fresh screening before it can be promoted or shown.
    attribute(:fresh_until, :utc_datetime_usec, allow_nil?: true, public?: true)

    # Set when a screening is wanted and cleared when it has run; the
    # screening job picks up every row with it set.
    attribute(:screen_requested_at, :utc_datetime_usec, allow_nil?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: false, public?: true)
    belongs_to(:market, Patchbay.Offers.Market, allow_nil?: true, public?: true)
  end

  calculations do
    calculate(
      :approved?,
      :boolean,
      expr(decision == :allow and not is_nil(fresh_until) and fresh_until > now()),
      public?: true
    )
  end

  actions do
    defaults([:read])

    create :request_safety do
      description("Asks for a version's safety screening, when it is first saved.")
      accept([:version_id])
      change(set_attribute(:kind, :safety))
      change(set_attribute(:screen_requested_at, &DateTime.utc_now/0))
      change(run_oban_trigger(:screen))
    end

    create :request_relevance do
      description("Asks whether a version suits a site's market, before bidding there.")
      accept([:version_id, :market_id])
      upsert?(true)
      upsert_identity(:unique_relevance)
      # Asking again for a review that already exists writes nothing; the
      # periodic refresh keeps an existing one current.
      upsert_fields([:version_id])
      change(set_attribute(:kind, :relevance))
      change(set_attribute(:screen_requested_at, &DateTime.utc_now/0))
      change(run_oban_trigger(:screen))
      validate(Patchbay.Offers.Validations.SiteMarket)
      validate(Patchbay.Offers.Validations.OwnsVersion)
    end

    update :rescreen do
      description("Asks for this review to be screened again.")
      accept([])
      change(set_attribute(:screen_requested_at, &DateTime.utc_now/0))
      change(run_oban_trigger(:screen))
    end

    update :screen do
      description("""
      Screens this review's version and keeps the decision. Pages are
      visited and Jev is asked, so nothing here holds a transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Offers.Screen)
    end

    update :screening_failed do
      description("Screening's last try failed; the version is turned down.")
      accept([])
      require_atomic?(false)
      # A request already answered while the last try ran stays answered.
      change(filter(expr(not is_nil(screen_requested_at))))
      change(set_attribute(:decision, :deny))
      change(set_attribute(:reason_codes, ["screening_unavailable"]))
      change(set_attribute(:fresh_until, nil))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(set_attribute(:screen_requested_at, nil))
      change(Patchbay.Offers.Changes.LogTurnDown)
    end

    update :record do
      description("Keeps a screening's decision and evidence.")

      accept([
        :decision,
        :reason_codes,
        :private_reason,
        :model,
        :policy_version,
        :input_sha256,
        :destinations
      ])

      # The freshness depends on the decision written, so it is worked out
      # from the changeset rather than in the database.
      require_atomic?(false)

      argument(:fresh_for_us, :integer, allow_nil?: false, constraints: [min: 0])

      # The request this screening answered. The decision is kept only while
      # that request is still the current one, in the same statement: a
      # newer request made while it ran leaves the row untouched, and the
      # newer request is screened in turn.
      argument(:answers_request_at, :utc_datetime_usec, allow_nil?: false)

      change(filter(expr(screen_requested_at == ^arg(:answers_request_at))))
      change(set_attribute(:screen_requested_at, nil))
      change(Patchbay.Offers.Changes.RecordDecision)
      change(Patchbay.Offers.Changes.LogTurnDown)
    end
  end

  identities do
    identity(:unique_safety, [:version_id], where: expr(kind == :safety))
    identity(:unique_relevance, [:version_id, :market_id], where: expr(kind == :relevance))
  end

  policies do
    # The owner reads the reviews of their own versions; screening reads and
    # writes them inside Patchbay's own actions, which skip authorization
    # deliberately.
    policy action_type(:read) do
      authorize_if(expr(version.creative.owner_profile_id == ^actor(:id)))
    end

    policy action(:request_relevance) do
      authorize_if(actor_present())
    end
  end
end
