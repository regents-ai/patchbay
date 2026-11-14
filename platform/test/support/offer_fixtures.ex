defmodule PatchbayTest.OfferFixtures do
  @moduledoc """
  Agent offers in tests: a market switched on for one test, people who sign
  in with their own wallets, Patchbay's word on wallets and campaigns, and
  placement and lease rows as the market's reader writes them.
  """

  alias Patchbay.{Accounts, Identity, ModeratorFixtures, Offers}

  @system %{role: :system}
  @market "0x00000000000000000000000000000000000000aa"

  @doc "The market address tests switch the feature on with."
  def market, do: @market

  @doc """
  Switches agent offers on for the running test, with `settings` over the
  test defaults, and back off when it ends.
  """
  def offers_on!(settings \\ []) do
    original = Application.fetch_env!(:patchbay, Offers)

    Application.put_env(
      :patchbay,
      Offers,
      Keyword.merge(original, Keyword.merge([market_address: @market], settings))
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:patchbay, Offers, original) end)
  end

  @doc """
  A person signed in through Privy whose account links `wallet`, read as the
  site reads the signed-in profile, with the account's wallets.
  """
  def person!(wallet) do
    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:offers-#{System.unique_integer([:positive])}",
        wallet_address: wallet
      })

    now = System.system_time(:second)

    {:ok, _account} =
      Accounts.establish(%RegentPrivy.Session{
        app_id: "test-app",
        session_id: "test-session",
        privy_user_id: profile.privy_user_id,
        wallet_address: wallet,
        wallet_addresses: [wallet],
        issued_at: now,
        expires_at: now + 600
      })

    Identity.get_profile!(profile.id, load: [:wallet_addresses])
  end

  @doc "A fresh lowercase wallet address."
  def wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  @doc "A campaign written by `person` for their own wallet."
  def campaign!(person, attrs \\ %{}) do
    Offers.write_campaign!(
      Map.merge(
        %{
          advertiser: person.wallet_address,
          title: "Acme payments",
          body: "Take card payments in one line of code.",
          link: "https://acme.example/agents",
          audience: :all
        },
        attrs
      ),
      actor: person
    )
  end

  @doc """
  Patchbay's word on `wallet`, given by a moderator. The moderator list is
  shared by every test, so only a test that runs alone may call it.
  """
  def rule!(wallet, verdict \\ :accepted),
    do: Offers.set_advertiser_rule!(wallet, verdict, actor: ModeratorFixtures.moderator())

  @doc "Patchbay approves `campaign`, by a moderator; as `rule!/2`, only in a test that runs alone."
  def approve!(campaign),
    do: Offers.approve_campaign!(campaign.campaign_id, actor: ModeratorFixtures.moderator())

  @doc """
  A campaign by `person` that Patchbay shows: its wallet accepted and the
  campaign approved. As `rule!/2`, only in a test that runs alone.
  """
  def shown_campaign!(person, attrs \\ %{}) do
    rule!(person.wallet_address)
    campaign = campaign!(person, attrs)
    approve!(campaign)
    campaign
  end

  @doc "A `PlacementCreated` row for the listed site `origin`, as the reader writes it."
  def placement!(placement_id, origin, attrs \\ %{}) do
    Offers.record_placement!(
      Map.merge(
        event(placement_id * 10),
        %{
          placement_id: placement_id,
          source_id: Offers.hash(origin),
          capacity: 3,
          duration_seconds: 72 * 3600,
          min_bump_bps: 1_000,
          floor_usdc: Decimal.new(5_000_000),
          policy_hash: Offers.policy_hash(),
          metadata_uri: "https://patchbay.help/" <> origin,
          source_origin: origin
        }
      )
      |> Map.merge(attrs),
      actor: @system
    )
  end

  @doc "A `LeasePurchased` row for `campaign` in a slot, as the reader writes it."
  def lease!(placement_id, slot, campaign, attrs \\ %{}) do
    starts_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Offers.record_lease!(
      Map.merge(
        event(placement_id * 10 + slot + 1 + System.unique_integer([:positive])),
        %{
          placement_id: placement_id,
          slot: slot,
          buyer: campaign.advertiser,
          campaign_id: campaign.campaign_id,
          paid_usdc: Decimal.new(5_000_000),
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 72 * 3600),
          nonce: 1
        }
      )
      |> Map.merge(attrs),
      actor: @system
    )
  end

  defp event(n) do
    %{
      chain_id: 8453,
      market: @market,
      transaction_hash: hash(n),
      log_index: 0,
      block_number: n,
      block_hash: hash(n + 1_000_000)
    }
  end

  defp hash(n),
    do: ("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")) |> String.downcase()
end
