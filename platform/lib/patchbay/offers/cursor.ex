defmodule Patchbay.Offers.Cursor do
  @moduledoc """
  How far Patchbay's market has been read on its chain, always at the latest
  block: the first block not read yet, and the head last seen and when.

  A reading that disagrees with the record sets `rescan_from` and stops the
  reading until a person corrects the record and clears it (`:clear`, from
  `mix patchbay.offers clear-stop`).
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @address ~r/\A0x[0-9a-f]{40}\z/
  @hash ~r/\A0x[0-9a-f]{64}\z/

  # On Base the record is behind once its head was read more than 420
  # seconds ago (one five-minute turn and two retries a minute apart), or it
  # is more than ten minutes of blocks (3,000) behind that head.
  @stale_seconds 420
  @behind_blocks 3_000

  postgres do
    table("agent_offer_cursors")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:chain_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
    attribute(:market, :string, allow_nil?: false, public?: true, constraints: [match: @address])
    # The first block not read yet.
    attribute(:next_block, :integer, allow_nil?: false, public?: true, constraints: [min: 0])
    attribute(:head_block, :integer, public?: true, constraints: [min: 0])
    attribute(:head_block_hash, :string, public?: true, constraints: [match: @hash])
    attribute(:observed_at, :utc_datetime_usec, public?: true)
    attribute(:rescan_from, :integer, public?: true, constraints: [min: 0])

    timestamps()
  end

  identities do
    identity(:unique_cursor, [:chain_id, :market])
  end

  calculations do
    calculate(
      :fresh?,
      :boolean,
      expr(
        not is_nil(observed_at) and observed_at > ago(@stale_seconds, :second) and
          head_block - next_block < @behind_blocks
      )
    )
  end

  actions do
    defaults([:read])

    # Leaves a cursor already there as it stands.
    create :open do
      accept([:chain_id, :market, :next_block])
      upsert?(true)
      upsert_identity(:unique_cursor)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
    end

    # Moves only a cursor still where this pass found it and not stopped, so a
    # second machine's pass or a hand correction is never undone.
    update :advance do
      accept([:next_block, :head_block, :head_block_hash, :observed_at])
      require_attributes([:next_block, :head_block, :head_block_hash, :observed_at])
      argument(:from, :integer, allow_nil?: false)
      validate(Patchbay.Offers.CursorUnmoved)
    end

    # Keeps the earliest block where the chain disagreed with the record.
    update :stop do
      accept([])
      require_atomic?(true)
      argument(:block, :integer, allow_nil?: false, constraints: [min: 0])

      change(
        atomic_update(
          :rescan_from,
          expr(
            if is_nil(rescan_from) or rescan_from > ^arg(:block),
              do: ^arg(:block),
              else: rescan_from
          )
        )
      )
    end

    # A person corrected the record by hand and reading may go on.
    update :clear do
      accept([:next_block])
      change(set_attribute(:rescan_from, nil))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:open, :advance, :stop, :clear]) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
end
