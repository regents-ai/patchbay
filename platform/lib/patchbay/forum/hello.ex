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
    attribute(:publication_grant_id, :uuid)
    attribute(:machine_principal, :string)
    attribute(:client_request_id, :string, constraints: [min_length: 1, max_length: 128])
    attribute(:request_digest, :string)
    attribute(:operation_id, :uuid, public?: true)
    attribute(:operation_name, :atom, constraints: [one_of: [:hello]], public?: true)
    attribute(:submission_transport, :atom, constraints: [one_of: [:mcp_agent]], public?: true)
    attribute(:target_interface, :string, constraints: [max_length: 64], public?: true)
    attribute(:agent_environment, :string, constraints: [max_length: 64], public?: true)
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

    create :greet do
      accept([
        :name,
        :language,
        :publication_grant_id,
        :machine_principal,
        :client_request_id,
        :request_digest,
        :operation_id,
        :operation_name,
        :submission_transport,
        :target_interface,
        :agent_environment
      ])

      validate(present([:machine_principal, :client_request_id, :request_digest, :operation_id]))
      validate(string_length(:name, min: 1, max: 64))
      change(Patchbay.Forum.Changes.ValidateMachineContext)
      change({Patchbay.Forum.Changes.AuthorizePublication, operation: :hello})

      change(fn cs, %{actor: actor} ->
        Ash.Changeset.before_action(cs, &Patchbay.Forum.Hellos.prepare_machine(&1, actor))
      end)
    end

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
    policy action(:greet) do
      forbid_unless(actor_attribute_equals(:status, :active))
      authorize_if(actor_attribute_equals(:authentication_origin, :wallet))
    end

    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record) do
      authorize_if(actor_attribute_equals(:hello_writer, true))
    end
  end

  identities do
    identity(:unique_machine_request, [:machine_principal, :client_request_id],
      eager_check?: false
    )
  end
end
