defmodule Patchbay.Assist.FeeStatesTest do
  @moduledoc """
  Where the fee of an assist paid for before paid assists ended stands, and
  what may move it: every step names the stored states it starts from and is
  checked against the row as it is now, not as the caller last read it; a
  person can finish a forward left forwarding or failed; the database keeps
  the fee's states and its deposit transaction in step; and the operator
  wallet's held-fees figure counts only fees it really holds.
  """

  use Patchbay.DataCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  import Patchbay.AssistFixtures, only: [paid_payment: 2, paid_run: 2]

  alias Patchbay.Assist
  alias Patchbay.Identity
  alias Patchbay.OperatorWallet

  @states [:pending, :forwarding, :deposited, :failed, :no_fee]

  # The wallet a paid assist was paid into.
  @pay_to "0x" <> String.duplicate("c", 40)

  # Each step, what it is given, and the stored states it may start from.
  @steps [
    {:take_fee, %{}, [:pending]},
    {:release_fee, %{}, [:forwarding]},
    {:record_deposited, %{deposit_tx_hash: "0x01"}, [:forwarding, :failed]},
    {:record_fee_failed, %{deposit_tx_hash: "0x02"}, [:forwarding]},
    {:fee_not_forwarded, %{}, [:pending]},
    {:forward_fee_again, %{}, [:forwarding, :failed]}
  ]

  for {step, input, from} <- @steps do
    test "#{step} moves a fee only stored in #{inspect(from)}, whatever the caller read" do
      for state <- @states do
        run = store(answered_run(profile()), state)

        # A copy read while the fee was in a state the step starts from.
        stale = %{run | deposit_status: hd(unquote(from))}
        result = step(stale, unquote(step), unquote(Macro.escape(input)))

        if state in unquote(from),
          do: assert({:ok, _moved} = result, "refused from #{state}"),
          else: assert({:error, _refused} = result, "moved from #{state}")
      end
    end
  end

  test "a person writes a forward deposited only with the transaction it landed in" do
    # A person at Patchbay's console, for a forward left with no transaction.
    stuck = store(answered_run(profile()), :forwarding)
    assert {:error, _} = Assist.record_deposited(stuck.id, %{}, authorize?: false)

    assert {:ok, %{deposit_status: :deposited, deposit_tx_hash: "0x0a"}} =
             Assist.record_deposited(stuck.id, %{deposit_tx_hash: "0x0a"}, authorize?: false)

    # A failed forward whose deposit the chain shows landed keeps the
    # transaction it was sent in.
    sent = store(answered_run(profile()), :failed, "0x0b")

    assert {:ok, %{deposit_status: :deposited, deposit_tx_hash: "0x0b"}} =
             Assist.record_deposited(sent, %{}, authorize?: false)
  end

  test "a fee put back after a failed forward forgets the deposit and is forwarded again" do
    run = store(answered_run(profile()), :failed, "0x0c")
    Patchbay.Repo.delete_all(Oban.Job)

    # A person at Patchbay's console, once the chain shows nothing landed,
    # naming the run by its id as the console does.
    assert {:ok, back} = Assist.forward_fee_again(run.id, authorize?: false)
    assert {back.deposit_status, back.deposit_tx_hash} == {:pending, nil}
    assert_triggered(back, :forward_fee)
  end

  test "the database keeps the fee's states and its deposit transaction in step" do
    run = answered_run(profile())

    for {status, hash} <- [
          {"lost", nil},
          {"pending", "0x0d"},
          {"forwarding", "0x0d"},
          {"no_fee", "0x0d"},
          {"deposited", nil}
        ] do
      assert_raise Postgrex.Error, ~r/assist_runs_deposit/, fn ->
        Patchbay.Repo.transaction(fn -> raw_store(run.id, status, hash) end)
      end
    end

    for {status, hash} <- [{"failed", nil}, {"failed", "0x0e"}, {"deposited", "0x0e"}] do
      assert {1, _} = raw_store(run.id, status, hash)
    end
  end

  test "the held-fees figure counts fees the operator wallet holds and no others" do
    payer = profile()
    answered_run(payer)
    store(answered_run(profile()), :forwarding)
    store(answered_run(profile()), :failed)
    store(answered_run(profile()), :failed, "0x0f")
    store(answered_run(profile()), :deposited)
    settled_with_no_run(profile())
    settled_with_no_run(profile())

    # Waiting, being forwarded, failed with nothing sent, and two paid with no run.
    assert OperatorWallet.assist_fees_unforwarded_usdc() == 0.5
  end

  defp profile do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:fee-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    })
  end

  defp settled_with_no_run(payer), do: paid_payment(payer, @pay_to)

  # A paid run Patchbay answered, its fee waiting to be forwarded.
  defp answered_run(payer) do
    run = paid_run(payer, @pay_to)

    # Patchbay's own job answering it.
    {:ok, running} = Assist.start_run(run, authorize?: false)
    Assist.finish_run!(running, %{status: :finished, outcome: :reached}, authorize?: false)
  end

  # Puts the stored fee in `state`, behind the back of any copy already read,
  # and answers the run as it now stands; a deposited fee names its
  # transaction, as the database asks.
  defp store(run, state, hash \\ nil) do
    hash = if state == :deposited, do: hash || "0x09", else: hash
    {1, _} = raw_store(run.id, Atom.to_string(state), hash)
    # Read back as Patchbay's own jobs read it, as nobody in particular.
    Assist.get_run!(run.id, authorize?: false)
  end

  # Patchbay's own job, or a person at its console.
  defp step(run, action, input), do: Ash.update(run, input, action: action, authorize?: false)

  # Writes the row behind Ash on purpose: to put a fee in a state no step
  # reaches from where it stands, and to try states the database must refuse.
  defp raw_store(id, status, hash) do
    Patchbay.Repo.update_all(
      from(run in "assist_runs", where: run.id == type(^id, Ecto.UUID)),
      set: [deposit_status: status, deposit_tx_hash: hash]
    )
  end
end
