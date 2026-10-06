defmodule Patchbay.Offers.MarketTest do
  # Markets: one Global market and at most one per site, each with exactly
  # three slots, however many times or ways a market is opened.
  use Patchbay.DataCase, async: true

  alias Patchbay.Forum
  alias Patchbay.Offers

  test "Global is open with its three slots" do
    global = Offers.global_market!(load: [:slots])
    assert global.scope == :global
    assert Enum.map(global.slots, & &1.number) == [1, 2, 3]
  end

  test "opening a site's market twice leaves one market with three slots" do
    {:ok, site} =
      Forum.register_site("offers-#{System.unique_integer([:positive])}.example",
        authorize?: false
      )

    first = Offers.open_site_market!(site.id, authorize?: false)
    second = Offers.open_site_market!(site.id, authorize?: false)

    assert first.id == second.id

    market = Ash.load!(second, :slots)
    assert Enum.map(market.slots, & &1.number) == [1, 2, 3]
  end

  test "the database refuses a second Global market" do
    assert_raise Postgrex.Error, ~r/offer_markets_one_global/, fn ->
      Repo.query!("""
      INSERT INTO offer_markets (id, scope, policy_revision, inserted_at)
      VALUES (gen_random_uuid(), 'global', 1, now())
      """)
    end
  end
end
