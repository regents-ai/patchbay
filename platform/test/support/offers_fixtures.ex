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
  An active placement of `version` in `market`'s slot `number`. Options:
  `:starts_at` (default now), so a test can place one that has run out.
  """
  def place(market, number, version, opts \\ []) do
    # A fixture reads back what it set up, so it skips policies deliberately.
    %{creative: %{owner_profile_id: owner_id}} = Ash.load!(version, :creative, authorize?: false)
    # As above.
    %{slots: slots} = Ash.load!(market, :slots, authorize?: false)
    slot = Enum.find(slots, &(&1.number == number))
    starts_at = Keyword.get(opts, :starts_at, DateTime.utc_now())
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
        (id, owner_profile_id, version_id, slot_id, window_id, lane, account_id, hold_id,
         amount_minor, minimum_minor, opening_minimum_minor, policy_revision, duration_us,
         target_generation, target_next_revision, idempotency_key, request_sha256, status,
         accepted_at, inserted_at)
      VALUES ($1, $2, $3, $4, $5, 'immediate', gen_random_uuid(), gen_random_uuid(),
              100, 100, 100, 1, $6, 0, 0, gen_random_uuid()::text, 'test', 'placed', $7, $7)
      """,
      [
        uuid.(bid_id),
        uuid.(owner_id),
        uuid.(version.id),
        uuid.(slot.id),
        uuid.(window_id),
        @duration_us,
        starts_at
      ]
    )

    Repo.query!(
      """
      INSERT INTO offer_placements
        (id, owner_profile_id, version_id, slot_id, bid_id, account_id, hold_id, amount_minor,
         minimum_minor, policy_revision, duration_us, generation, starts_at, expires_at, status)
      VALUES ($1, $2, $3, $4, $5, gen_random_uuid(), gen_random_uuid(), 100, 100, 1, $6, 1,
              $7, $7::timestamp + ($6::bigint * interval '1 microsecond'), 'active')
      """,
      [
        uuid.(placement_id),
        uuid.(owner_id),
        uuid.(version.id),
        uuid.(slot.id),
        uuid.(bid_id),
        @duration_us,
        starts_at
      ]
    )

    # As above.
    Ash.get!(Offers.Placement, placement_id, authorize?: false)
  end
end
