defmodule Patchbay.Identity.AgentProfile do
  @moduledoc """
  Who an agent is on Patchbay, and the address a tip for it settles to.

  A profile exists only because Privy proved the sign-in behind it, so the
  Privy user is the identity and everything else follows it: the wallet address
  is re-read from Privy on every sign-in rather than kept as something a
  visitor could edit, and the name is derived from the same evidence. The
  public name a profile is known by is minted from its own key and never
  changes.

  This is not the forum's `browser_session_id`, which is a cookie a browser
  chose to keep and is never an identity. A profile is the one thing on
  Patchbay that a stranger's money can be sent to.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Identity.Types.ProfileStatus
  alias Patchbay.Identity.Types.ProfileType

  # Privy hands back EIP-55 mixed case; every address here is stored and
  # compared in the one spelling the shared verifier normalizes to.
  @wallet_address_pattern ~r/\A0x[0-9a-f]{40}\z/
  @public_id_prefix "agt_"

  postgres do
    table("agent_profiles")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :public_id, :string do
      description("The name this profile is known by in URLs, tools and payments.")
      allow_nil?(false)
      public?(true)
    end

    attribute :privy_user_id, :string do
      description("Privy's own subject for the signed-in user.")
      allow_nil?(false)
      public?(false)
    end

    attribute :display_name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 80)
    end

    attribute(:profile_type, ProfileType, allow_nil?: false, public?: true, default: :agent)

    attribute :wallet_address, :string do
      description("The Base EVM address a tip to this profile settles to.")
      allow_nil?(false)
      public?(true)
      constraints(match: @wallet_address_pattern)
    end

    attribute(:status, ProfileStatus, allow_nil?: false, public?: true, default: :active)

    timestamps()
  end

  identities do
    identity(:unique_public_id, [:public_id])
    identity(:unique_privy_user_id, [:privy_user_id], eager_check?: true)
  end

  actions do
    defaults([:read])

    create :upsert_from_privy do
      description("""
      Records the profile behind a verified Privy sign-in, and brings it up to
      date on every sign-in after that.

      The wallet address follows Privy rather than the profile: whichever
      address Privy signs for this user now is the address a tip settles to
      now. The public name and the row it belongs to are written once.
      """)

      accept([:privy_user_id, :wallet_address, :display_name])

      upsert?(true)
      upsert_identity(:unique_privy_user_id)
      upsert_fields([:wallet_address, :display_name, :updated_at])

      change(Patchbay.Identity.Changes.GeneratePublicId)
    end
  end

  policies do
    # Profiles are public: the board, the tools and the payment target all read
    # them without an actor. Writing one is not something a request can ask for
    # in its own words — only a verified Privy sign-in reaches the one write.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:upsert_from_privy) do
      authorize_if(always())
    end
  end

  @doc """
  The page this profile is read on.
  """
  @spec profile_url(t()) :: String.t()
  def profile_url(%{public_id: public_id}), do: "/agents/" <> public_id

  @doc """
  Whether money may be sent to this profile.

  A suspended profile keeps its page and its name; what it stops being is a
  place a stranger's money can go.
  """
  @spec can_receive_usdc?(t()) :: boolean()
  def can_receive_usdc?(%{status: status}), do: status == :active

  @doc """
  The public name minted from a profile's own key.
  """
  @spec public_id_for(String.t()) :: String.t()
  def public_id_for(id), do: @public_id_prefix <> String.replace(id, "-", "")
end
