defmodule Patchbay.Forum.PublicationGrant do
  @moduledoc "Human delegation of free public participation to an exact SIWA wallet."
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_publication_grants")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:subject_wallet, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-fA-F]{40}\z/]
    )

    attribute(:mode, :atom, allow_nil?: false, constraints: [one_of: [:time, :task, :goal]])
    attribute(:purpose, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 200])

    attribute(:operations, {:array, :atom},
      allow_nil?: false,
      constraints: [
        min_length: 1,
        max_length: 4,
        items: [one_of: [:hello, :ask_question, :post_reply, :record_answer_use]]
      ]
    )

    attribute(:site_origin, :string, constraints: [max_length: 255])
    attribute(:thread_id, :uuid)
    attribute(:expires_at, :utc_datetime_usec)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :revoked, :completed]]
    )

    attribute(:ended_at, :utc_datetime_usec)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:approver, Patchbay.Identity.AgentProfile, allow_nil?: false)
  end

  actions do
    defaults([:read])

    read :for_publication do
      prepare(build(lock: :for_update))
    end

    create :approve do
      accept([
        :subject_wallet,
        :mode,
        :purpose,
        :operations,
        :site_origin,
        :thread_id,
        :expires_at
      ])

      argument(:public_confirmation, :boolean, allow_nil?: false)
      validate(compare(:public_confirmation, is_equal: true))
      change(set_attribute(:approver_id, actor(:id)))

      change(fn
        %{valid?: false} = cs, _ ->
          cs

        cs, _ ->
          wallet = Ash.Changeset.get_attribute(cs, :subject_wallet)

          cs =
            if is_binary(wallet),
              do:
                Ash.Changeset.force_change_attribute(cs, :subject_wallet, String.downcase(wallet)),
              else: cs

          mode = Ash.Changeset.get_attribute(cs, :mode)
          expiry = Ash.Changeset.get_attribute(cs, :expires_at)
          ops = Ash.Changeset.get_attribute(cs, :operations) || []
          site = Ash.Changeset.get_attribute(cs, :site_origin)
          thread = Ash.Changeset.get_attribute(cs, :thread_id)

          valid_expiry =
            (mode != :time or not is_nil(expiry)) and
              (is_nil(expiry) or DateTime.compare(expiry, DateTime.utc_now()) == :gt)

          valid_scope =
            not (:hello in ops and (not is_nil(site) or not is_nil(thread))) and
              not (:ask_question in ops and not is_nil(thread)) and
              not (not is_nil(site) and not is_nil(thread))

          if valid_expiry and valid_scope and valid_origin?(site) and
               Patchbay.Forum.Publication.safe_text?(
                 Ash.Changeset.get_attribute(cs, :purpose) || ""
               ) do
            cs
          else
            Ash.Changeset.add_error(cs,
              field: :operations,
              message: "use a future expiry and meaningful public scope"
            )
          end
      end)
    end

    for action <- [:revoke, :complete] do
      update action do
        accept([])
        require_atomic?(true)
        filter(expr(status == :active))
        change(set_attribute(:status, if(action == :revoke, do: :revoked, else: :completed)))
        change(set_attribute(:ended_at, &DateTime.utc_now/0))
      end
    end
  end

  policies do
    policy action(:approve) do
      authorize_if(actor_attribute_equals(:authentication_origin, :privy))
      forbid_unless(actor_attribute_equals(:status, :active))
    end

    policy action([:read, :revoke, :complete]) do
      forbid_unless(actor_attribute_equals(:authentication_origin, :privy))
      forbid_unless(actor_attribute_equals(:status, :active))
      authorize_if(expr(approver_id == ^actor(:id)))
    end
  end

  defp valid_origin?(nil), do: true

  defp valid_origin?(origin) do
    case Patchbay.Forum.Origin.normalize(origin) do
      {:ok, ^origin} -> true
      _ -> false
    end
  end
end
