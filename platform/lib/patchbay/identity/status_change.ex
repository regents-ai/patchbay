defmodule Patchbay.Identity.StatusChange do
  @moduledoc """
  The record of a profile being suspended or reinstated at Patchbay's console:
  which profile, which of the two, the reason given, and when. Each row is
  written in the same transaction as the change it records, and rows are never
  updated or deleted: a profile suspended again later gets a new row.

  Nothing public reads these. They hold ids and the reason, never a copy of
  anything the person wrote. The console reads a profile's rows with
  `Patchbay.Release.status_changes/2`.
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
    end
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes the row for a suspension or reinstatement already made.")
      accept([:profile_id, :action, :reason])
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
    # The suspension and reinstatement that write a row and the console that
    # reads them all act as the system actor (`Patchbay.Release`), which no
    # request carries.
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
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
  end
end
