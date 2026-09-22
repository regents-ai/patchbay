defmodule Patchbay.Assist.ForwardTest do
  @moduledoc """
  A paid assist's fee goes from the operator wallet to the REGENT staking
  contract: an approval of exactly the fee, then the deposit, each signed
  with the operator key and sent to a fake Base. What the chain says is
  written on the run, and a fee that cannot be forwarded never touches the
  answer.
  """

  use Patchbay.DataCase, async: false

  import Plug.Conn

  alias Ethers.Contracts.ERC20
  alias Ethers.Transaction
  alias Patchbay.Assist
  alias Patchbay.Assist.Forward
  alias Patchbay.Assist.Staking
  alias Patchbay.Identity
  alias Patchbay.Payments
  alias Patchbay.Payments.USDC

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
    run = paid_run()

    assert :ok = Forward.run(run.id)

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

    # Forwarded once; a second pass sends nothing more.
    assert :ok = Forward.run(run.id)
    assert length(sent(chain)) == 2
  end

  test "an approval the chain refuses ends the forward as failed with nothing deposited" do
    chain = chain(receipts: fn _hash -> "0x0" end)
    run = paid_run()

    assert :ok = Forward.run(run.id)

    # Read as the worker reads it, as nobody in particular.
    {:ok, failed} = Assist.get_run(run.id, authorize?: false)
    assert failed.deposit_status == :failed
    assert failed.deposit_tx_hash == nil
    assert [_approve] = sent(chain)
  end

  test "with no staking contract set the fee stays where it was paid, and nothing is sent" do
    chain = chain(receipts: fn _hash -> "0x1" end)
    Application.put_env(:patchbay, :assist, pay_to_address: @payer)
    run = paid_run()

    assert :ok = Forward.run(run.id)

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

    Application.put_env(:patchbay, :escrow,
      contract_address: nil,
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: "http://127.0.0.1:#{port}"
    )

    Application.put_env(:patchbay, :assist,
      pay_to_address: @payer,
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

  # A paid, opened run whose payment receipt names the payer wallet.
  defp paid_run do
    payer =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:forward-#{Ecto.UUID.generate()}",
        wallet_address: @payer
      })

    request = %{
      "goal" => "Book the 9am table for two on Friday",
      "site_url" => "https://bookings.example.com/mcp",
      "sign_in" => "unknown",
      "expected_result" => "A confirmation with a booking reference",
      "believed_calls" => []
    }

    {:ok, intent} = Payments.prepare_jev_assist(%{request: request}, actor: payer)
    {:ok, settled} = Ash.update(intent, %{}, action: :mark_settled, actor: payer)
    tx = "0x" <> String.duplicate("e", 64)

    {:ok, _receipt} =
      Payments.record_payment_receipt(
        %{
          payment_intent_id: settled.id,
          payment_identifier: settled.payment_identifier,
          payer_address: @payer,
          network: settled.network,
          asset: settled.asset,
          amount_atomic: settled.amount_atomic,
          facilitator: "https://example.invalid/facilitator",
          transaction_hash: tx,
          payment_response: %{"success" => true, "transaction" => tx},
          settled_at: DateTime.utc_now()
        },
        actor: payer
      )

    {:ok, run} = Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: payer)
    run
  end
end
