defmodule Patchbay.Identity.PairingTest do
  @moduledoc """
  Pairing an agent with a person: a code pairs one agent, once, within ten
  minutes; the pair share one balance on the person's lines, and what the
  agent held moves there as it pairs; only the person unpairs, and after
  that the agent starts again from nothing of its own.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias Patchbay.Identity.PairingCode
  alias Patchbay.Payments.Credits

  @credit 1_000_000

  setup do
    %{person: person(), agent: agent()}
  end

  test "a code pairs one agent, once, and the pair share the person's balance", %{
    person: person,
    agent: agent
  } do
    {:ok, :credited} = Credits.record_card_purchase(person.id, 500, payment())

    assert {:ok, %{code: code, expires_at: expires_at}} = Pairing.issue(person)
    assert code =~ ~r/\A[A-HJ-KM-NP-Z2-9]{5}-[A-HJ-KM-NP-Z2-9]{5}\z/
    assert DateTime.diff(expires_at, DateTime.utc_now(), :minute) in 9..10

    # An agent may send it as it was copied, in lower case and without the hyphen.
    copied = code |> String.downcase() |> String.replace("-", "")
    assert {:ok, paired_with} = Pairing.pair(agent, copied)
    assert paired_with.id == person.id

    assert Identity.get_profile!(agent.id).paired_person_id == person.id
    assert [%{id: agent_id}] = Pairing.agents(person)
    assert agent_id == agent.id

    assert Credits.balance_atomic(agent.id) == 5 * @credit

    # Bought for the agent's wallet, the credits land on the person.
    {:ok, :credited} = Credits.record_card_purchase(agent.id, 200, payment())
    assert Credits.balance_atomic(person.id) == 7 * @credit
    assert Credits.history(agent) == []

    # The code is used up.
    assert {:error, :code_unknown} = Pairing.pair(agent(), code)
  end

  test "what an agent held on its own moves onto the person as it pairs", %{
    person: person,
    agent: agent
  } do
    {:ok, :credited} = Credits.record_card_purchase(agent.id, 300, payment())
    {:ok, :credited} = Credits.record_card_purchase(person.id, 100, payment())

    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)

    assert Credits.balance_atomic(person.id) == 4 * @credit
    assert Credits.balance_atomic(agent.id) == 4 * @credit

    assert [%{kind: :pairing_move, amount_atomic: 3_000_000} | _earlier] =
             Credits.history(person)

    assert [%{kind: :pairing_move, amount_atomic: -3_000_000}, %{kind: :card_purchase}] =
             Credits.history(agent)
  end

  test "a new code replaces the old one, and a code past ten minutes pairs nothing", %{
    person: person,
    agent: agent
  } do
    {:ok, %{code: first}} = Pairing.issue(person)
    {:ok, %{code: second}} = Pairing.issue(person)

    assert {:error, :code_unknown} = Pairing.pair(agent, first)

    Repo.update_all(PairingCode, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])
    assert {:error, :code_unknown} = Pairing.pair(agent, second)
    assert {:error, :code_unknown} = Pairing.pair(agent, "not a code")

    assert is_nil(Identity.get_profile!(agent.id).paired_person_id)
  end

  test "only the person unpairs, and the balance stays with them", %{
    person: person,
    agent: agent
  } do
    {:ok, :credited} = Credits.record_card_purchase(agent.id, 300, payment())
    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)

    stranger = person()
    assert {:error, %Ash.Error.Forbidden{}} = Pairing.unpair(stranger, agent.public_id)
    assert Identity.get_profile!(agent.id).paired_person_id == person.id

    assert {:ok, unpaired} = Pairing.unpair(person, agent.public_id)
    assert is_nil(unpaired.paired_person_id)
    assert Pairing.agents(person) == []

    assert Credits.balance_atomic(person.id) == 3 * @credit
    assert Credits.balance_atomic(agent.id) == 0
  end

  test "a code from another person moves the agent to them", %{person: person, agent: agent} do
    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)
    {:ok, :credited} = Credits.record_card_purchase(person.id, 200, payment())

    other = person()
    {:ok, %{code: other_code}} = Pairing.issue(other)
    {:ok, _other} = Pairing.pair(agent, other_code)

    assert Identity.get_profile!(agent.id).paired_person_id == other.id
    assert Pairing.agents(person) == []
    assert Credits.balance_atomic(person.id) == 2 * @credit
    assert Credits.balance_atomic(agent.id) == 0
  end

  test "only a person gives out codes, and only a wallet author pairs", %{person: person} do
    assert {:error, %Ash.Error.Forbidden{}} = Pairing.issue(agent())

    {:ok, %{code: code}} = Pairing.issue(person)
    assert {:error, %Ash.Error.Invalid{}} = Pairing.pair(person(), code)
  end

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:pairing-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("a", 40)
    })
  end

  defp agent do
    wallet = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    Identity.upsert_from_wallet!(%{wallet_address: wallet})
  end

  defp payment, do: "pi_" <> Ecto.UUID.generate()
end
