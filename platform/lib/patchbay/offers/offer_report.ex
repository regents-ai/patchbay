defmodule Patchbay.Offers.OfferReport do
  @moduledoc """
  An agent's or person's report that an Offer it was shown is a problem.

  A report names an Offer Patchbay returned: the placement and the exact
  wording, and optionally the response it came in. It never names a bare
  link. Each reporter reports a placement once; reporting it again answers
  with the first report, so retries and repeats never add to its count.

  The reporter is the signed-in account or the forum session, worked out by
  the server and never sent by the caller. The note is the reporter's own
  words and is untrusted text wherever it is read. A report costs nothing
  and never takes money from anyone on its own: a moderator decides.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @reasons [
    :malicious_link,
    :prompt_injection,
    :impersonation,
    :misleading,
    :irrelevant_placement,
    :other
  ]

  postgres do
    table("offer_reports")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:note, "offer_reports_note_size",
        check: "char_length(note) <= 2000 AND octet_length(note) <= 8192",
        message: "is longer than 2,000 characters or 8 KiB"
      )
    end

    custom_indexes do
      index([:status, :inserted_at])
      index([:placement_id, :inserted_at])
      index([:version_id])
    end

    references do
      reference(:placement, on_delete: :restrict)
      reference(:version, on_delete: :restrict)
      reference(:delivery, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    # `profile:` or `session:` and its id, as `Patchbay.Forum.Principal` writes it.
    attribute(:reporter, :string, allow_nil?: false)

    attribute(:surface, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:http_api, :native_mcp]]
    )

    attribute(:reason, :atom, allow_nil?: false, public?: true, constraints: [one_of: @reasons])

    attribute(:note, :string,
      allow_nil?: true,
      public?: true,
      constraints: [trim?: true, allow_empty?: false]
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      constraints: [one_of: [:open, :dismissed, :confirmed]]
    )

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:once_per_reporter, [:reporter, :placement_id])
  end

  relationships do
    belongs_to(:placement, Patchbay.Offers.Placement, allow_nil?: false, public?: true)
    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: false, public?: true)
    belongs_to(:delivery, Patchbay.Offers.Delivery, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    create :file do
      description(
        "Reports an Offer Patchbay returned. Reporting it again answers with the first report."
      )

      accept([:placement_id, :version_id, :delivery_id, :reason, :note])

      argument(:reporter, :string, allow_nil?: false)
      argument(:surface, :atom, allow_nil?: false)

      change(set_attribute(:reporter, arg(:reporter)))
      change(set_attribute(:surface, arg(:surface)))

      validate(Patchbay.Offers.Validations.KnownOffer, only_when_valid?: true)
      validate(Patchbay.Offers.Validations.NoteSize)

      upsert?(true)
      upsert_identity(:once_per_reporter)
      # A second report of the same placement writes nothing new.
      upsert_fields([:reporter])
    end
  end

  policies do
    # Filed only by Patchbay's forum doors, which name the reporter from the
    # request's own session and skip authorization deliberately; read only on
    # the moderator page.
    policy always() do
      forbid_if(always())
    end
  end
end
