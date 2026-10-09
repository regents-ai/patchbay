defmodule Patchbay.Credits.CreditedTest do
  # Crediting a purchase tells the site through `on_credited` inside the credit
  # itself. A site without that setting, or whose module fails, never credits a
  # purchase, and nothing shows it until a person pays. This credits one, as the
  # site's purchase check does once the chain shows the payment.
  use Patchbay.DataCase, async: true

  @person "did:privy:credits-test"
  @wallet "0x" <> String.duplicate("b", 40)

  test "a purchase credits with the site's on_credited module" do
    {:ok, purchase} =
      RegentCredits.Purchase
      |> Ash.Changeset.for_create(
        :record,
        %{
          privy_user_id: @person,
          wallet: @wallet,
          chain: :base,
          amount: 25,
          number: Ecto.UUID.generate(),
          tx_hash: "0x" <> String.duplicate("1", 64)
        },
        authorize?: false
      )
      |> Ash.create()

    assert {:ok, %{status: :credited}} =
             RegentCredits.Purchase
             |> Ash.ActionInput.for_action(:credit, %{id: purchase.id}, authorize?: false)
             |> Ash.run_action()

    assert Decimal.to_integer(RegentCredits.balance(@person).purchased) == 25
  end
end
