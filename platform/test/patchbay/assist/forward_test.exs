defmodule Patchbay.Assist.ForwardTest do
  @moduledoc """
  A paid assist's fee goes from the operator wallet to the REGENT staking
  contract, as the run's `:forward_fee` job: an approval of exactly the fee,
  then the deposit, each signed with the operator key and sent to a fake
  Base. What the chain says is written on the run, a fee is forwarded once
  however often its job runs, and a fee that cannot be forwarded never
  touches the answer.
  """

  use Patchbay.DataCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  import Plug.Conn

  alias Ethers.Contracts.ERC20
  alias Ethers.Transaction
  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias Patchbay.Identity
  alias Patchbay.Payments.JevAssist
  alias RegentPayments.FeeForward.Staking
  alias RegentPayments.USDC

  @staking "0x" <> String.duplicate("b", 40)
  @payer "0x" <> String.duplicate("a", 40)
  @source_tag "patchbay.assist" <> String.duplicate(<<0>>, 17)

  setup do
    old_assist = Application.get_env(:patchbay, :assist)
    old_escrow = Application.get_env(:patchbay, :escrow)

    on_exit(fn ->
      Application.put_env(:patchbay, :assist, old_assist)
      Application.put_env(:patchbay, :escrow, old_escrow)
    end)

    :ok
  end

  test "the fee is approved to the staking contract and deposited, tagged and referenced" do
    chain = chain(receipts: fn _hash -> "0x1" end)
    run = answered_run()

    assert %{success: 1} = forward(run)

    # The test reads the run the way the worker does, as nobody in particular.
    {:ok, forwarded} = Assist.get_run(run.id, authorize?: false)
    assert forwarded.deposit_status == :deposited
    assert [approve, deposit] = sent(chain)
    assert forwarded.deposit_tx_hash == hash(2)

    assert approve.nonce == 0
    assert approve.to == String.downcase(USDC.asset())
    assert approve.input == ERC20.approve(@staking, 100_000).data

    assert deposit.nonce == 1
    assert deposit.to == @staking

    payer_bytes = :binary.copy(<<0xAA>>, 20)

    assert deposit.input ==
             Staking.deposit_usdc(100_000, @source_tag, <<0::size(96), payer_bytes::binary>>).data

    # Forwarded once; a second job for the same fee sends nothing more.
    assert {:cancel, _} =
             perform_job(Run.Workers.ForwardFee, %{"primary_key" => %{"id" => run.id}})

    assert length(sent(chain)) == 2
  end

  test "a fee already being forwarded is not forwarded again by another job" do
    chain = chain(receipts: fn _hash -> "0x1" end)
    run = answered_run()
    {:ok, _taken} = Assist.take_fee(run, authorize?: false)

    # The other job read the fee while it still waited, and took it too late.
    assert {:error, _} = Ash.update(run, %{}, action: :forward_fee, authorize?: false)
    assert sent(chain) == []
  end

  test "an approval the chain refuses is tried again, then left failed with nothing deposited" do
    chain = chain(receipts: fn _hash -> "0x0" end)
    run = answered_run()

    assert %{failure: 2, success: 1} = forward(run)

    # Read as the worker reads it, as nobody in particular.
    {:ok, failed} = Assist.get_run(run.id, authorize?: false)
    assert failed.deposit_status == :failed
    assert failed.deposit_tx_hash == nil
    assert [_approve, _again, _last] = sent(chain)
  end

  test "a deposit the chain reverts is left failed with its hash and never sent blind again" do
    chain = chain(receipts: fn hash -> if hash == hash(1), do: "0x1", else: "0x0" end)
    run = answered_run()

    assert %{success: 1} = forward(run)

    # Read as the worker reads it, as nobody in particular.
    {:ok, failed} = Assist.get_run(run.id, authorize?: false)
    assert {failed.deposit_status, failed.deposit_tx_hash} == {:failed, hash(2)}
    assert [_approve, _deposit] = sent(chain)
  end

  test "with no staking contract set the fee stays where it was paid, and nothing is sent" do
    chain = chain(receipts: fn _hash -> "0x1" end)
    Application.put_env(:patchbay, :assist, pay_to_address: @payer)
    run = answered_run()

    assert %{success: 1} = forward(run)

    # Read as the worker reads it, as nobody in particular.
    {:ok, waiting} = Assist.get_run(run.id, authorize?: false)
    assert waiting.deposit_status == :pending
    assert sent(chain) == []
  end

  # A fake Base: counts the operator's transactions for the nonce, hands back
  # a hash per transaction sent, and answers each receipt with `receipts`'
  # status for the hash. Every raw transaction it receives is kept.
  defp chain(receipts: receipts) do
    seen = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: fn conn, _ ->
             {:ok, body, conn} = read_body(conn)
             request = Jason.decode!(body)
             answer = rpc(request, seen, receipts)

             conn
             |> put_resp_content_type("application/json")
             |> send_resp(200, Jason.encode!(answer))
           end,
           ip: {127, 0, 0, 1},
           port: 0},
          id: make_ref()
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    # The fee is paid into the operator wallet, the one that forwards it.
    key = :crypto.strong_rand_bytes(32)
    {:ok, operator} = X402.EIP3009.derive_address(key)

    Application.put_env(:patchbay, :escrow,
      contract_address: nil,
      operator_private_key: Base.encode16(key, case: :lower),
      rpc_url: "http://127.0.0.1:#{port}"
    )

    Application.put_env(:patchbay, :assist,
      pay_to_address: String.downcase(operator),
      staking_contract_address: @staking
    )

    seen
  end

  defp rpc(requests, seen, receipts) when is_list(requests),
    do: Enum.map(requests, &rpc(&1, seen, receipts))

  defp rpc(%{"id" => id, "method" => method} = request, seen, receipts) do
    result =
      case method do
        "eth_chainId" ->
          "0x7a69"

        "eth_getTransactionCount" ->
          "0x" <> Integer.to_string(length(Agent.get(seen, & &1)), 16)

        "eth_estimateGas" ->
          "0x186a0"

        "eth_gasPrice" ->
          "0x3b9aca00"

        "eth_maxPriorityFeePerGas" ->
          "0x1"

        "eth_feeHistory" ->
          %{
            oldestBlock: "0x0",
            baseFeePerGas: ["0x1", "0x1"],
            gasUsedRatio: [0.5],
            reward: [["0x1"]]
          }

        "eth_sendRawTransaction" ->
          [raw] = request["params"]
          Agent.update(seen, &(&1 ++ [raw]))
          hash(length(Agent.get(seen, & &1)))

        "eth_getTransactionReceipt" ->
          [hash] = request["params"]
          %{"transactionHash" => hash, "status" => receipts.(hash)}
      end

    %{jsonrpc: "2.0", id: id, result: result}
  end

  defp hash(n), do: "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")

  # The transactions the fake chain received, decoded, in the order sent.
  defp sent(seen) do
    seen
    |> Agent.get(& &1)
    |> Enum.map(fn raw ->
      {:ok, %Transaction.Signed{payload: payload}} = Transaction.decode(raw)
      %{payload | to: String.downcase(payload.to)}
    end)
  end

  # The run's fee job, queued when it was answered, run as Oban runs it,
  # retries included.
  defp forward(run) do
    assert_triggered(run, :forward_fee)
    Oban.drain_queue(queue: :fees, with_scheduled: true, with_recursion: true)
  end

  # A paid run Patchbay answered, whose payment receipt names the payer wallet.
  defp answered_run do
    payer =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:forward-#{Ecto.UUID.generate()}",
        wallet_address: @payer
      })

    request = %{
      "goal" => "Book the 9am table for two on Friday",
      "site_url" => "https://bookings.example.com/mcp",
      "error" => nil,
      "sign_in" => "unknown",
      "believed_calls" => []
    }

    {:ok, intent} = RegentPayments.Purchase.prepare(JevAssist, %{request: request}, payer)
    {settled, _receipt} = Patchbay.SettledPayment.settle!(intent, payer)
    {:ok, run} = Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: payer)

    # Patchbay's own job answering it.
    {:ok, running} = Assist.start_run(run, authorize?: false)
    Assist.finish_run!(running, %{status: :finished, outcome: :reached}, authorize?: false)
  end
end
