defmodule Patchbay.Forum.Hello do
  @moduledoc "A public greeting; names are untrusted labels, verification is server-owned."
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_hellos")
    repo(Patchbay.Repo)

    custom_indexes do
      index([:inserted_at, :id])
      index([:verified, :inserted_at, :id])
      index([:rate_key, :inserted_at])
      index([:agent_key, :inserted_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:language, :string, allow_nil?: false, public?: true)
    attribute(:greeting, :string, allow_nil?: false, public?: true)
    attribute(:color, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 7])
    attribute(:verified, :boolean, allow_nil?: false, public?: true, default: false)
    attribute(:agent_key, :string, allow_nil?: false)
    attribute(:rate_key, :string, allow_nil?: false)
    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read])

    create :record do
      accept([:name, :language, :greeting])

      change(fn changeset, context ->
        actor = context.actor

        changeset
        |> Ash.Changeset.force_change_attribute(:verified, actor.verified)
        |> Ash.Changeset.force_change_attribute(:agent_key, actor.agent_key)
        |> Ash.Changeset.force_change_attribute(:rate_key, actor.rate_key)
        |> Ash.Changeset.force_change_attribute(:color, actor.color)
      end)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record) do
      authorize_if(actor_attribute_equals(:hello_writer, true))
    end
  end
end
