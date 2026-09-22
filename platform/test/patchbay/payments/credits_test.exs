defmodule Patchbay.Payments.CreditsTest do
  @moduledoc """
  The Patchbay Credits ledger as Stripe's word writes it: one purchase per
  card payment however often Stripe says so, refunds taken back by Stripe's
  running total, each dispute taken back once, never more taken back from a
  card payment than it bought, and nothing done for a card payment that was
  not a bundle.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Payments.Credits

  @credit 1_000_000

  setup do
    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:credits-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("c", 40)
      })

    %{profile: profile, payment: "pi_" <> Ecto.UUID.generate()}
  end

  test "a bundle is credited once, however often Stripe says it was paid", %{
    profile: profile,
    payment: payment
  } do
    assert Credits.balance_atomic(profile.id) == 0

    assert {:ok, :credited} = Credits.record_card_purchase(profile.id, 500, payment)
    assert {:ok, :already_credited} = Credits.record_card_purchase(profile.id, 500, payment)

    assert Credits.balance_atomic(profile.id) == 5 * @credit
    assert [%{kind: :card_purchase, amount_atomic: 5_000_000}] = Credits.history(profile)
  end

  test "refunds are taken back by Stripe's running total", %{profile: profile, payment: payment} do
    {:ok, :credited} = Credits.record_card_purchase(profile.id, 1_000, payment)

    assert {:ok, :reversed} = Credits.record_card_refund(payment, 300)
    assert Credits.balance_atomic(profile.id) == 7 * @credit

    # The same event again, then a second refund whose total includes the first.
    assert {:ok, :already_reversed} = Credits.record_card_refund(payment, 300)
    assert {:ok, :reversed} = Credits.record_card_refund(payment, 1_000)
    assert Credits.balance_atomic(profile.id) == 0
  end

  test "a dispute is taken back once, and never beyond what the payment bought", %{
    profile: profile,
    payment: payment
  } do
    {:ok, :credited} = Credits.record_card_purchase(profile.id, 1_000, payment)
    {:ok, :reversed} = Credits.record_card_refund(payment, 400)

    assert {:ok, :reversed} = Credits.record_card_dispute(payment, "du_1", 1_000)
    assert {:ok, :already_reversed} = Credits.record_card_dispute(payment, "du_1", 1_000)

    # 4 refunded, so the dispute of the whole 10 takes back only the other 6.
    assert Credits.balance_atomic(profile.id) == 0

    assert [-6_000_000, -4_000_000, 10_000_000] =
             profile |> Credits.history() |> Enum.map(& &1.amount_atomic)
  end

  test "a card payment that was not a bundle writes nothing", %{payment: payment} do
    assert {:ok, :not_ours} = Credits.record_card_refund(payment, 500)
    assert {:ok, :not_ours} = Credits.record_card_dispute(payment, "du_2", 500)
  end

  test "a profile's lines are its own to read", %{profile: profile, payment: payment} do
    {:ok, :credited} = Credits.record_card_purchase(profile.id, 200, payment)

    stranger =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:stranger-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("d", 40)
      })

    assert Credits.history(stranger) == []
    assert [_line] = Credits.history(profile)
  end

  test "only the bundles on sale can be bought" do
    assert Credits.bundles() == [2, 5, 10, 20, 50]
    assert Credits.bundle?(5)
    refute Credits.bundle?(7)
    refute Credits.bundle?("5")
  end
end
