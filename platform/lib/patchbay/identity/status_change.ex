defmodule Patchbay.Identity.StatusChange do
  @moduledoc """
  The record of a profile being suspended or reinstated by Patchbay's staff:
  which profile, which of the two, the reason given, when, and the moderator
  who did it (none when it was done at the console). Each row is written in
  the same transaction as the change it records, and rows are never updated or
  deleted: a profile suspended again later gets a new row.

  Only the two profile actions write a row
  (`Patchbay.Identity.Changes.RecordStatusChange`): `record` has no interface
  of its own and refuses any call that is not theirs, whoever the actor is.
  The moderator is read from the acting actor, never from what a caller sends.

  Nothing public reads these. They hold ids and the reason, never a copy of
  anything the person wrote. The console reads a profile's rows with
  `Patchbay.Release.status_changes/2`, and a moderator reads them on the
  person's admin page (`PatchbayWeb.PersonAdminLive`).
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("agent_profile_status_changes")
    repo(Patchbay.Repo)

    references do
      reference(:profile, on_delete: :restrict)
      # A moderator's profile cannot be deleted out from under the record.
      reference(:moderator, on_delete: :restrict)
    end
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes the row for a suspension or reinstatement already made.")
      public?(false)
      accept([:profile_id, :action, :reason])
      # The console's system actor has no profile, so its rows name nobody.
      change(relate_actor(:moderator, allow_nil?: true))
    end

    read :for_profile do
      description("A profile's suspensions and reinstatements, oldest first.")

      argument :profile_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(profile_id == ^arg(:profile_id)))
      prepare(build(sort: [inserted_at: :asc]))
    end
  end

  policies do
    # A row is written only from inside the suspension or reinstatement it
    # records (`Patchbay.Identity.Changes.RecordStatusChange`), whose own
    # policy has already judged the actor. Called on its own, it is refused.
    policy action(:record) do
      authorize_if(context_equals(:profile_status_action?, true))
    end

    # Rows are read by Patchbay's staff: the console's system actor
    # (`Patchbay.Release`), which code builds and no request supplies, or a
    # moderator's own active web sign-in, the same two
    # `Patchbay.Identity.AgentProfile` admits to the two actions.
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :system))
      forbid_unless(actor_attribute_equals(:authentication_origin, :privy))
      forbid_unless(actor_attribute_equals(:status, :active))
      authorize_if(Patchbay.Checks.Moderator)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:suspend, :reinstate]]
    )

    attribute(:reason, :string, allow_nil?: false, public?: true, constraints: [max_length: 500])

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to :profile, Patchbay.Identity.AgentProfile do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :moderator, Patchbay.Identity.AgentProfile do
      description("The moderator who made the change; empty when the console did.")
      public?(true)
    end
  end
end
