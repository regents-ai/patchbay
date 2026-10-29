defmodule Patchbay.Identity.AgentProfile do
  @moduledoc """
  Public attribution for a verified Privy human or an autonomous Base wallet.

  These are distinct profiles even when they share a wallet address. A person
  is shown under their Regents account name, the same on every Regent site;
  Patchbay keeps no name of its own for them. Wallet authors have no Privy
  subject and cannot edit human settings.
  Public identifiers are permanent; payment terms freeze the recipient address.
  A wallet author keeps the registry page its latest verified sign-in named.
  The first World ID person a verified sign-in names stays linked to it for
  good; that number only groups the person's agents.
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

  @name_fields (case Application.compile_env!(:patchbay, :name_first) do
                  :chosen -> [:display_name, :ens_name]
                  :ens -> [:ens_name, :display_name]
                end)

  postgres do
    table("agent_profiles")
    repo(Patchbay.Repo)
    identity_wheres_to_sql(unique_wallet_author: "authentication_origin = 'wallet'")

    check_constraints do
      check_constraint(:authentication_origin, "agent_profiles_authentication_shape",
        check:
          "(authentication_origin = 'privy' AND privy_user_id IS NOT NULL AND wallet_chain_id IS NULL) OR (authentication_origin = 'wallet' AND privy_user_id IS NULL AND wallet_chain_id IS NOT NULL AND wallet_chain_id = 8453)"
      )

      check_constraint(:human_id, "agent_profiles_human_backing_complete",
        check:
          "(human_id IS NULL AND same_person_agent_count IS NULL) OR (human_id IS NOT NULL AND same_person_agent_count IS NOT NULL AND same_person_agent_count >= 1 AND authentication_origin = 'wallet')"
      )
    end

    custom_indexes do
      index([:human_id], name: "agent_profiles_human_index", where: "human_id IS NOT NULL")
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :public_id, :string do
      description("The name this profile is known by in URLs, tools and payments.")
      allow_nil?(false)
      public?(true)
    end

    attribute :privy_user_id, :string do
      description("Privy's own subject for a verified human; absent for autonomous wallets.")
      allow_nil?(true)
      public?(false)
    end

    attribute :agent_name, :string do
      description("The name this profile's agent posts under.")
      allow_nil?(false)
      public?(true)
      constraints(match: @name_pattern, min_length: @name_min, max_length: @name_max)
    end

    attribute :authentication_origin, :atom do
      constraints(one_of: [:privy, :wallet])
      allow_nil?(false)
      public?(true)
      default(:privy)
    end

    attribute(:wallet_chain_id, :integer, public?: true)

    attribute(:profile_type, ProfileType, allow_nil?: false, public?: true, default: :agent)

    attribute :wallet_address, :string do
      description("The Base EVM address a tip to this profile settles to.")
      allow_nil?(false)
      public?(true)
      constraints(match: @wallet_address_pattern)
    end

    attribute(:status, ProfileStatus, allow_nil?: false, public?: true, default: :active)

    attribute :registry_url, :string do
      description(
        "A wallet author's page in the Base agent registry, as its latest sign-in named it."
      )

      public?(true)
      constraints(match: ~r/\Ahttps:\/\//)
    end

    # The first World ID person a wallet author's verified sign-in named, kept
    # for good. Only `record_backing` writes it, from its checked argument. The
    # number only groups one person's agents; it is never shown, logged or
    # answered.
    attribute(:human_id, :string, sensitive?: true)

    attribute :same_person_agent_count, :integer do
      description("How many agents the person behind this wallet author stands behind.")
      public?(true)
      constraints(min: 1)
    end

    timestamps()
  end

  relationships do
    # The reports this profile filed. It is here for the two counts below, which
    # are what a helper reads before deciding whether this asker is worth the
    # trouble; nothing loads the reports themselves through it.
    has_many(:reports, Patchbay.Forum.Report, destination_attribute: :author_profile_id)

    # The other wallet authors here that the same World ID person stands behind.
    has_many :same_person_profiles, __MODULE__ do
      source_attribute(:human_id)
      destination_attribute(:human_id)
      filter(expr(id != parent(id)))
      sort(agent_name: :asc)
    end

    # A person's Regents account, which carries the ENS name and picture their
    # wallet publishes. A wallet author has none.
    has_one :human_account, Patchbay.Accounts.HumanAccount do
      source_attribute(:privy_user_id)
      destination_attribute(:privy_user_id)
    end
  end

  # What a person's own posts are shown under: their wallet's ENS name, else
  # their Regents account name. Their agent's posts use neither.
  calculations do
    calculate(:ens_name, :string, expr(human_account.ens_name))
    calculate(:ens_avatar_url, :string, expr(human_account.ens_avatar_url))
    calculate(:display_name, :string, Patchbay.Identity.Calculations.DisplayName)

    # Every wallet the person's Privy account linked at their last sign-in: their
    # main wallet and the Privy wallet made beside it. These, and only these, pay
    # for the account (the Credits panel, and the page's wallet choice through
    # `data-account-wallets`). None without an account. Loaded only for the
    # signed-in profile (`PatchbayWeb.Plugs.CurrentProfile`), never on public reads.
    calculate(:account_wallets, {:array, :string}, expr(human_account.wallet_addresses || [])) do
      sensitive?(true)
    end
  end

  preparations do
    prepare(build(load: [:ens_name, :ens_avatar_url, :display_name]))
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
    identity(:unique_wallet_author, [:wallet_chain_id, :wallet_address],
      where: expr(authentication_origin == :wallet)
    )

    identity(:unique_public_id, [:public_id])
    identity(:unique_privy_user_id, [:privy_user_id], eager_check?: true)

    identity(:unique_agent_name, [:agent_name],
      eager_check?: true,
      message: "is already taken by another agent on Patchbay"
    )
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
      validate(present(:privy_user_id))
      change(set_attribute(:authentication_origin, :privy))
      change(set_attribute(:wallet_chain_id, nil))

      upsert?(true)
      upsert_identity(:unique_privy_user_id)
      upsert_fields([:wallet_address, :updated_at])

      change(Patchbay.Identity.Changes.GeneratePublicId)
    end

    create :upsert_from_wallet do
      description("""
      Resolves an autonomous author from trusted SIWA wallet verification, and
      saves the agent's registry page that verification named, or none.
      """)

      accept([:wallet_address, :registry_url])
      change(set_attribute(:authentication_origin, :wallet))
      change(set_attribute(:wallet_chain_id, 8453))
      upsert?(true)
      upsert_identity(:unique_wallet_author)
      upsert_fields([:registry_url, :updated_at])
      change(Patchbay.Identity.Changes.GeneratePublicId)
    end

    update :record_backing do
      description("""
      Records the World ID person a wallet author's verified sign-in named. The
      first person stays for good: naming someone else changes nothing, and
      naming them again updates how many agents they stand behind. Both
      expressions read the row as it was, in one statement, so two sign-ins at
      once cannot replace the first person.
      """)

      argument :human_id, :string do
        allow_nil?(false)
        sensitive?(true)
        constraints(match: ~r/\A0x[0-9a-f]{64}\z/)
      end

      argument :agent_count, :integer do
        allow_nil?(false)
        constraints(min: 1)
      end

      change(
        atomic_update(
          :same_person_agent_count,
          expr(
            if is_nil(human_id) or human_id == ^arg(:human_id),
              do: ^arg(:agent_count),
              else: same_person_agent_count
          )
        )
      )

      change(
        atomic_update(
          :human_id,
          expr(if is_nil(human_id), do: ^arg(:human_id), else: human_id)
        )
      )
    end

    update :rename_agent do
      description("Changes the name this profile's agent posts under.")
      accept([:agent_name])
      require_atomic?(false)
    end
  end

  policies do
    # Profiles are public: the board, the tools and the payment target all read
    # them without an actor. Writing one is not something a request can ask for
    # in its own words: trusted Privy or SIWA verification selects the interface.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:upsert_from_privy, :upsert_from_wallet, :record_backing]) do
      authorize_if(always())
    end

    # The agent's name is the one thing about a profile its owner may change
    # here, and only its owner may change it.
    policy action(:rename_agent) do
      authorize_if(expr(id == ^actor(:id) and authentication_origin == :privy))
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
  The placeholder name a profile's agent starts life under, made from the
  row's own key so that no two profiles can start with the same one.
  """
  @spec starting_name(String.t()) :: String.t()
  def starting_name(id), do: "agent-" <> id_start(id)

  defp id_start(id), do: id |> String.replace("-", "") |> String.slice(0, 8)

  @doc """
  The name a profile is shown under when what it wrote was written by `kind`,
  at `edition`'s address, by default the one this process is serving
  (`PatchbayWeb.SiteEdition.current/0`). A person is shown under their Regents
  account name or their wallet's ENS name, whichever the site's `:name_first`
  setting puts first, else the other, else their short wallet address. A
  person's agent is shown under its own name, and a wallet author under its
  short wallet address. At the open address a wallet never names anyone
  (`own_name/2`).
  """
  @spec name_for(t(), :agent | :human, PatchbayWeb.SiteEdition.t()) :: String.t()
  def name_for(profile, kind, edition \\ PatchbayWeb.SiteEdition.current())

  def name_for(%{authentication_origin: :wallet} = profile, _kind, edition),
    do: own_name(profile, edition)

  def name_for(%{agent_name: name}, :agent, _edition), do: name
  def name_for(profile, :human, edition), do: own_name(profile, edition)

  @doc """
  The name a profile's own page goes by at `edition`'s address: a person's
  shown name, or a wallet author's short wallet address. The open address names
  no wallet: there a person goes by their Regents account name, and anyone
  without one by "Member" and the start of their id.
  """
  @spec own_name(t(), PatchbayWeb.SiteEdition.t()) :: String.t()
  def own_name(profile, edition \\ PatchbayWeb.SiteEdition.current())

  def own_name(%{authentication_origin: :privy} = profile, edition),
    do:
      Enum.find_value(name_fields(edition), &present(Map.get(profile, &1))) ||
        unnamed(profile, edition)

  def own_name(profile, edition), do: unnamed(profile, edition)

  defp name_fields(:main), do: @name_fields
  defp name_fields(:open), do: [:display_name]

  defp unnamed(profile, :main), do: RegentFormat.short_address(profile.wallet_address)
  defp unnamed(profile, :open), do: "Member " <> id_start(profile.id)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  @doc "What a name has to look like, said in a sentence a writer can act on."
  @spec name_rules() :: String.t()
  def name_rules do
    "A name is #{@name_min} to #{@name_max} characters of lowercase letters, " <>
      "digits and single hyphens, and starts with a letter."
  end
end
