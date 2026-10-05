defmodule Patchbay.OffersFixtures do
  @moduledoc """
  Running Offers for tests that read what is showing. Bidding is not built
  yet, so a placement is written straight into the tables, in the shape a
  won window leaves behind: a settled window, its placed bid, and the
  placement it started.
  """

  alias Patchbay.Identity
  alias Patchbay.Offers
  alias Patchbay.Repo

  @duration_us 259_200_000_000

  @doc "A new signed-in advertiser."
  def advertiser do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:offers-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("c", 40)
    })
  end

  @doc """
  A signed-in profile on the moderator list for the rest of the test. Call it
  from inside a test or setup, which puts the list back when the test ends.
  The list is shared by every test, so only a test that runs alone may call it.
  """
  def moderator do
    wallet =
      "0x" <> (Ecto.UUID.generate() |> String.replace("-", "") |> String.pad_trailing(40, "0"))

    previous = Application.get_env(:patchbay, :moderator_wallets)
    Application.put_env(:patchbay, :moderator_wallets, [wallet | List.wrap(previous)])

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :moderator_wallets, previous),
        else: Application.delete_env(:patchbay, :moderator_wallets)
    end)

    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:moderator-#{Ecto.UUID.generate()}",
      wallet_address: wallet
    })
  end

  @doc """
  Blocks `version` as `moderator`, through the moderator's own action.
  """
  def block(version, moderator, reason \\ "misleading") do
    version
    |> Ash.Changeset.for_update(:block, %{reason: reason, idempotency_key: Ecto.UUID.generate()},
      actor: moderator
    )
    |> Ash.update!()
  end

  @doc """
  A saved Offer with `text`, allowed by safety screening, and also allowed for
  `market` when that is a site market. Options: `:fresh_until`, when the
  allows stop counting (default a day from now).
  """
  def approved_version(owner, text, market, opts \\ []) do
    {:ok, _creative} = Offers.create_creative("Offer", text, actor: owner)

    [version] =
      Offers.CreativeVersion
      |> Ash.read!(actor: owner)
      |> Enum.filter(&(&1.text == text))

    fresh_until = Keyword.get(opts, :fresh_until, DateTime.add(DateTime.utc_now(), 1, :day))

    if market.scope == :site do
      {:ok, _review} = Offers.request_market_review(version.id, market.id, actor: owner)
    end

    Repo.query!(
      """
      UPDATE offer_reviews
         SET decision = 'allow', decided_at = now(), fresh_until = $2, screen_requested_at = NULL
       WHERE version_id = $1
      """,
      [Ecto.UUID.dump!(version.id), fresh_until]
    )

    version
  end

  @doc """
  An active placement of `version` in `market`'s slot `number`, which the
  slot points at. Options: `:starts_at` (default now), so a test can place
  one that has run out, and `:amount_minor` (default 100).
  """
  def place(market, number, version, opts \\ []) do
    # A fixture reads back what it set up, so it skips policies deliberately.
    %{creative: %{owner_profile_id: owner_id}} = Ash.load!(version, :creative, authorize?: false)
    # As above.
    %{slots: slots} = Ash.load!(market, :slots, authorize?: false)
    slot = Enum.find(slots, &(&1.number == number))
    starts_at = Keyword.get(opts, :starts_at, DateTime.utc_now())
    amount = Keyword.get(opts, :amount_minor, 100)
    [window_id, bid_id, placement_id] = for _ <- 1..3, do: Ecto.UUID.generate()
    uuid = &Ecto.UUID.dump!/1

    Repo.query!(
      """
      INSERT INTO offer_bid_windows
        (id, slot_id, lane, target_generation, target_next_revision, opened_at, closes_at, state, settled_at)
      VALUES ($1, $2, 'immediate', 0, 0, $3, $3::timestamp + interval '2 seconds', 'won', $3::timestamp + interval '2 seconds')
      """,
      [uuid.(window_id), uuid.(slot.id), starts_at]
    )

    Repo.query!(
      """
      INSERT INTO offer_bids
        (id, owner_profile_id, version_id, slot_id, window_id, lane, payer_address, funding, commit_tx_hash,
         amount_minor, minimum_minor, opening_minimum_minor, policy_revision, duration_us,
         target_generation, target_next_revision, idempotency_key, request_sha256, status,
         accepted_at, inserted_at)
      VALUES ($1, $2, $3, $4, $5, 'immediate', '0x' || repeat('c', 40), 'funded', '0x' || md5(random()::text) || md5(random()::text),
              $8, 100, 100, 1, $6, 0, 0, gen_random_uuid()::text, 'test', 'placed', $7, $7)
      """,
      [
        uuid.(bid_id),
        uuid.(owner_id),
        uuid.(version.id),
        uuid.(slot.id),
        uuid.(window_id),
        @duration_us,
        starts_at,
        amount
      ]
    )

    Repo.query!(
      """
      INSERT INTO offer_placements
        (id, owner_profile_id, version_id, slot_id, bid_id, amount_minor,
         minimum_minor, policy_revision, duration_us, generation, starts_at, expires_at, status)
      VALUES ($1, $2, $3, $4, $5, $8, 100, 1, $6, 1,
              $7, $7::timestamp + ($6::bigint * interval '1 microsecond'), 'active')
      """,
      [
        uuid.(placement_id),
        uuid.(owner_id),
        uuid.(version.id),
        uuid.(slot.id),
        uuid.(bid_id),
        @duration_us,
        starts_at,
        amount
      ]
    )

    Repo.query!(
      "UPDATE offer_slots SET active_placement_id = $1, active_generation = 1 WHERE id = $2",
      [uuid.(placement_id), uuid.(slot.id)]
    )

    # As above.
    Ash.get!(Offers.Placement, placement_id, authorize?: false)
  end

  @doc """
  `version` committed as the next-period leader of `market`'s slot `number`
  at `amount_minor`, in the shape a won next-period window leaves behind.
  """
  def lead_next(market, number, version, amount_minor) do
    # A fixture reads back what it set up, so it skips policies deliberately.
    %{creative: %{owner_profile_id: owner_id}} = Ash.load!(version, :creative, authorize?: false)
    # As above.
    %{slots: slots} = Ash.load!(market, :slots, authorize?: false)
    slot = Enum.find(slots, &(&1.number == number))
    [window_id, bid_id] = for _ <- 1..2, do: Ecto.UUID.generate()
    uuid = &Ecto.UUID.dump!/1

    Repo.query!(
      """
      INSERT INTO offer_bid_windows
        (id, slot_id, lane, target_generation, target_next_revision, opened_at, closes_at, state, settled_at)
      VALUES ($1, $2, 'next_period', 1, 0, now(), now() + interval '2 seconds', 'won', now() + interval '2 seconds')
      """,
      [uuid.(window_id), uuid.(slot.id)]
    )

    Repo.query!(
      """
      INSERT INTO offer_bids
        (id, owner_profile_id, version_id, slot_id, window_id, lane, payer_address, funding, commit_tx_hash,
         amount_minor, minimum_minor, opening_minimum_minor, policy_revision, duration_us,
         target_generation, target_next_revision, idempotency_key, request_sha256, status,
         accepted_at, inserted_at)
      VALUES ($1, $2, $3, $4, $5, 'next_period', '0x' || repeat('c', 40), 'funded', '0x' || md5(random()::text) || md5(random()::text),
              $6, 100, 100, 1, $7, 1, 0, gen_random_uuid()::text, 'test', 'leading', now(), now())
      """,
      [
        uuid.(bid_id),
        uuid.(owner_id),
        uuid.(version.id),
        uuid.(slot.id),
        uuid.(window_id),
        amount_minor,
        @duration_us
      ]
    )

    Repo.query!(
      "UPDATE offer_slots SET next_bid_id = $1, next_revision = 1 WHERE id = $2",
      [uuid.(bid_id), uuid.(slot.id)]
    )

    # As above.
    Ash.get!(Offers.Bid, bid_id, authorize?: false)
  end

  @doc """
  `placement` ended with `status` and where its USDC went, in the shape
  settlement leaves behind; the slot no longer points at it.
  """
  def end_placement(placement, status, returned_minor, forfeited_minor) do
    uuid = &Ecto.UUID.dump!/1

    Repo.query!(
      """
      UPDATE offer_placements
         SET status = $2, ended_at = starts_at + interval '1 day', returned_minor = $3,
             forfeited_minor = $4, consumed_minor = amount_minor - $3 - $4
       WHERE id = $1
      """,
      [uuid.(placement.id), Atom.to_string(status), returned_minor, forfeited_minor]
    )

    Repo.query!("UPDATE offer_slots SET active_placement_id = NULL WHERE id = $1", [
      uuid.(placement.slot_id)
    ])
  end

  @doc """
  The next-period leader `bid` returned in full for `reason`; the slot no
  longer points at it.
  """
  def return_bid(bid, reason) do
    uuid = &Ecto.UUID.dump!/1

    Repo.query!(
      "UPDATE offer_bids SET status = 'returned', return_reason = $2, resolved_at = now() WHERE id = $1",
      [uuid.(bid.id), Atom.to_string(reason)]
    )

    Repo.query!("UPDATE offer_slots SET next_bid_id = NULL WHERE id = $1", [uuid.(bid.slot_id)])
  end
end
