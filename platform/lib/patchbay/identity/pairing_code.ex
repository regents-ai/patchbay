defmodule Patchbay.Identity.PairingCode do
  @moduledoc """
  The one code a person has given out to pair an agent with them.

  Only the code's sha256 is kept, so the table never holds a code that could
  be used. A person has one code at a time: asking for another replaces it.
  A code stands for ten minutes and pairs one agent, and is gone once used.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @minutes 10

  postgres do
    table("pairing_codes")
    repo(Patchbay.Repo)

    references do
      reference(:person, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:code_sha256, :string, allow_nil?: false, public?: false)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:one_code_per_person, [:person_id])
    identity(:unique_code, [:code_sha256])
  end

  relationships do
    belongs_to(:person, Patchbay.Identity.AgentProfile, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :issue do
      description("Gives the signed-in person a new code, in place of any they had.")

      accept([:code_sha256])
      upsert?(true)
      upsert_identity(:one_code_per_person)
      upsert_fields([:code_sha256, :expires_at, :inserted_at])

      change(relate_actor(:person))

      change(set_attribute(:expires_at, &__MODULE__.expiry/0))
    end

    read :live do
      description("The code with this sha256, while it still stands, locked until it is used.")

      argument(:code_sha256, :string, allow_nil?: false)
      get?(true)
      filter(expr(code_sha256 == ^arg(:code_sha256) and expires_at > now()))
      prepare(build(lock: "FOR UPDATE"))
    end

    destroy(:use_up)
  end

  policies do
    # Only a person, signed in with Privy, pairs agents with themselves.
    policy action(:issue) do
      authorize_if(actor_attribute_equals(:authentication_origin, :privy))
    end

    # Reading a code by its sha256 and using it up is the pairing process's,
    # for the wallet that sent it; nothing else reads or removes one.
  end

  @doc "How long a code stands, in minutes."
  @spec minutes() :: pos_integer()
  def minutes, do: @minutes

  @doc "When a code given out now stops standing."
  @spec expiry() :: DateTime.t()
  def expiry, do: DateTime.add(DateTime.utc_now(), @minutes, :minute)
end
