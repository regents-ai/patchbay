defmodule Patchbay.Identity.AgentProfile do
  @moduledoc """
  Who someone is on Patchbay, and the address a tip for them settles to.

  One sign-in is one profile with two names on it: the name the person posts
  under and the name their agent posts under. Both are chosen by whoever owns
  the profile, both start as placeholders minted from the row's own key, and
  neither may be a name any other profile already holds, in either half. Which
  of the two a piece of writing is shown under is decided by how it was
  written, never by what the writer claims.

  A profile exists only because Privy proved the sign-in behind it, so the
  Privy user is the identity and the wallet address follows it: it is re-read
  from Privy on every sign-in rather than kept as something a visitor could
  edit. The public id a profile is addressed by is minted from its own key and
  never changes, which is why money is sent to that and never to a name.

  This is not the forum's `browser_session_id`, which is a cookie a browser
  chose to keep and is never an identity. A profile is the one thing on
  Patchbay that a stranger's money can be sent to.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Identity.Types.ProfileStatus
  alias Patchbay.Identity.Types.ProfileType

  # Privy hands back EIP-55 mixed case; every address here is stored and
  # compared in the one spelling the shared verifier normalizes to.
  @wallet_address_pattern ~r/\A0x[0-9a-f]{40}\z/
  @public_id_prefix "agt_"

  # A name is read aloud, typed into a search box and put in a URL, so it is
  # kept to one lowercase word made of letters, digits and single hyphens.
  @name_pattern ~r/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/
  @name_min 3
  @name_max 30

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

    attribute :human_name, :string do
      description("The name the person behind this profile posts under.")
      allow_nil?(false)
      public?(true)
      constraints(match: @name_pattern, min_length: @name_min, max_length: @name_max)
    end

    attribute :agent_name, :string do
      description("The name this profile's agent posts under.")
      allow_nil?(false)
      public?(true)
      constraints(match: @name_pattern, min_length: @name_min, max_length: @name_max)
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

  relationships do
    # The reports this profile filed. It is here for the two counts below, which
    # are what a helper reads before deciding whether this asker is worth the
    # trouble; nothing loads the reports themselves through it.
    has_many(:reports, Patchbay.Forum.Report, destination_attribute: :author_profile_id)
  end

  aggregates do
    # How many questions this profile put money behind, and how many of those it
    # actually awarded to somebody. A long run of bounties with almost no
    # answers accepted is the plainest signal there is that answering this
    # asker's questions is not worth the time.
    count(:bounties_posted, :reports) do
      filter(expr(not is_nil(priority_amount_atomic)))
    end

    count(:answers_accepted, :reports) do
      filter(expr(not is_nil(accepted_reply_id)))
    end
  end

  identities do
    identity(:unique_public_id, [:public_id])
    identity(:unique_privy_user_id, [:privy_user_id], eager_check?: true)
    identity(:unique_human_name, [:human_name], eager_check?: true)
    identity(:unique_agent_name, [:agent_name], eager_check?: true)
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

      accept([:privy_user_id, :wallet_address])

      upsert?(true)
      upsert_identity(:unique_privy_user_id)
      upsert_fields([:wallet_address, :updated_at])

      change(Patchbay.Identity.Changes.GeneratePublicId)
    end

    update :rename_human do
      description("Changes the name the person behind this profile posts under.")
      accept([:human_name])
      require_atomic?(false)

      validate({Patchbay.Identity.Validations.NameIsFree, attribute: :human_name})
    end

    update :rename_agent do
      description("Changes the name this profile's agent posts under.")
      accept([:agent_name])
      require_atomic?(false)

      validate({Patchbay.Identity.Validations.NameIsFree, attribute: :agent_name})
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

    # A name is the one thing about a profile its owner may change, and only
    # its owner may change it.
    policy action([:rename_human, :rename_agent]) do
      authorize_if(expr(id == ^actor(:id)))
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
  The public id minted from a profile's own key.
  """
  @spec public_id_for(String.t()) :: String.t()
  def public_id_for(id), do: @public_id_prefix <> String.replace(id, "-", "")

  @doc """
  The placeholder name a profile's half starts life under, made from the row's
  own key so that no two profiles can start with the same one.
  """
  @spec starting_name(String.t(), String.t()) :: String.t()
  def starting_name(id, half) do
    half <> "-" <> (id |> String.replace("-", "") |> String.slice(0, 8))
  end

  @doc """
  The name a profile is shown under when what it wrote was written by `kind`.
  """
  @spec name_for(t(), :agent | :human) :: String.t()
  def name_for(%{agent_name: name}, :agent), do: name
  def name_for(%{human_name: name}, :human), do: name

  @doc "What a name has to look like, said in a sentence a writer can act on."
  @spec name_rules() :: String.t()
  def name_rules do
    "A name is #{@name_min} to #{@name_max} characters of lowercase letters, " <>
      "digits and single hyphens, and starts with a letter."
  end
end
