defmodule PatchbayWeb.ChainNumbersTest do
  @moduledoc """
  Sentinel reads these from Patchbay's metrics listener (fly-sentinel
  docs/metrics-contract.md): chain requests with no answer, the age of the
  operator wallet's oldest unconfirmed send for each flow, the paid priority
  reports whose escrow credit the chain has not yet confirmed, and the assist
  fees the operator wallet has not yet sent to staking. Labels are fixed
  names only.
  """

  use Patchbay.DataCase, async: false

  import ExUnit.CaptureLog

  alias Patchbay.Assist
  alias Patchbay.ChainClient
  alias Patchbay.Forum
  alias Patchbay.Identity
  alias Patchbay.OperatorWallet
  alias Patchbay.Payments.JevAssist
  alias PatchbayWeb.Telemetry

  @contract String.duplicate("e", 64)
  @arguments String.duplicate("f", 64)

  test "a chain request with no answer counts by method, class, chain and scope" do
    old_nodes = Application.get_env(:patchbay, :chain_nodes)
    on_exit(fn -> Application.put_env(:patchbay, :chain_nodes, old_nodes) end)
    Application.put_env(:patchbay, :chain_nodes, %{8453 => "http://127.0.0.1:9"})

    labels = [~s(method="eth_blockNumber"), ~s(class="transport"), ~s(chain_id="8453")]
    before = value("health_chain_request_failures_total", [~s(scope="wallet") | labels]) || 0

    assert {:error, _} = ChainClient.block_number(%{chain_id: 8453})

    assert value("health_chain_request_failures_total", [~s(scope="wallet") | labels]) ==
             before + 1
  end

  test "the operator wallet's chain request with no answer counts under its own scope" do
    old_escrow = Application.get_env(:patchbay, :escrow, [])
    on_exit(fn -> Application.put_env(:patchbay, :escrow, old_escrow) end)

    # A throwaway key that signs nothing and reaches no chain.
    Application.put_env(:patchbay, :escrow,
      contract_address: "0x" <> String.duplicate("a", 40),
      operator_private_key: "0x" <> String.duplicate("11", 32),
      rpc_url: "http://127.0.0.1:9"
    )

    labels = [~s(method="eth_call"), ~s(class="transport"), ~s(chain_id="8453")]
    before = value("health_chain_request_failures_total", [~s(scope="operator") | labels]) || 0

    assert {:error, _no_answer} = Patchbay.Escrow.post(Ecto.UUID.generate())

    assert value("health_chain_request_failures_total", [~s(scope="operator") | labels]) ==
             before + 1
  end

  test "a revert is the contract's answer; an HTTP or JSON-RPC error is none" do
    labels = [~s(method="eth_call"), ~s(chain_id="8453"), ~s(scope="operator")]
    count = fn class -> value("health_chain_request_failures_total", [class | labels]) || 0 end
    before = Map.new(~w(rpc http_503), &{&1, count.(~s(class="#{&1}"))})

    answer(200, ~s({"jsonrpc":"2.0","id":1,"error":{"code":3,"message":"execution reverted"}}))

    answer(
      200,
      ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}})
    )

    answer(200, ~s({"jsonrpc":"2.0","id":1,"result":"0x"}))
    assert count.(~s(class="rpc")) == before["rpc"]

    answer(200, ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"limit exceeded"}}))
    answer(503, "")
    assert count.(~s(class="rpc")) == before["rpc"] + 1
    assert count.(~s(class="http_503")) == before["http_503"] + 1
  end

  test "each operator flow's oldest unconfirmed send has its age, 0 when none waits" do
    asker = profile("asker")

    report =
      submitted(paid_report(asker), DateTime.add(DateTime.utc_now(), -120, :second))

    assert {"escrow_credit", %DateTime{}} =
             List.keyfind(OperatorWallet.unconfirmed_sends(), "escrow_credit", 0)

    assert {"fee_forward", nil} =
             List.keyfind(OperatorWallet.unconfirmed_sends(), "fee_forward", 0)

    assert :ok = Telemetry.oldest_unconfirmed_sends({OperatorWallet, :unconfirmed_sends, []})

    assert value("health_wallet_unconfirmed_oldest_seconds", [~s(flow="escrow_credit")]) >= 120
    assert value("health_wallet_unconfirmed_oldest_seconds", [~s(flow="fee_forward")]) == 0

    # Once the chain confirms it, nothing of the flow waits.
    {:ok, _} =
      Forum.confirm_escrow_credit(report, %{escrow_funded_at: DateTime.utc_now()},
        authorize?: false
      )

    assert :ok = Telemetry.oldest_unconfirmed_sends({OperatorWallet, :unconfirmed_sends, []})
    assert value("health_wallet_unconfirmed_oldest_seconds", [~s(flow="escrow_credit")]) == 0
  end

  test "escrow money not yet recorded and assist fees not yet forwarded are counted" do
    old_assist = Application.get_env(:patchbay, :assist)
    on_exit(fn -> Application.put_env(:patchbay, :assist, old_assist) end)
    Application.put_env(:patchbay, :assist, pay_to_address: "0x" <> String.duplicate("c", 40))

    asker = profile("bounty")
    waiting = paid_report(asker)
    submitted(paid_report(asker), DateTime.utc_now())

    {:ok, _confirmed} =
      paid_report(asker)
      |> submitted(DateTime.utc_now())
      |> Forum.confirm_escrow_credit(%{escrow_funded_at: DateTime.utc_now()}, authorize?: false)

    run = answered_run()
    {:ok, taken} = Assist.take_fee(answered_run(), authorize?: false)

    {:ok, _deposited} =
      Assist.record_deposited(taken, %{deposit_tx_hash: hash()}, authorize?: false)

    assert OperatorWallet.escrow_unrecorded() == 2
    assert run.deposit_status == :pending
    assert OperatorWallet.assist_fees_unforwarded_usdc() == 0.1

    Telemetry.measure_operator_wallet_waiting()
    assert value("patchbay_escrow_unrecorded", []) == 2
    assert value("patchbay_assist_fees_unforwarded_usdc", []) == 0.1

    assert waiting.escrow_status == nil
  end

  test "a query that fails is logged and the tick skipped" do
    log =
      capture_log(fn ->
        assert :ok = Telemetry.oldest_unconfirmed_sends({__MODULE__, :unanswered, []})
      end)

    assert log =~ "unconfirmed send age not measured: no answer"
  end

  def unanswered, do: raise("no answer")

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:chain-numbers-#{subject}-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("a", 40)
    })
  end

  defp paid_report(asker) do
    site = Forum.register_site!("shop-#{System.unique_integer([:positive])}.example.com")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: @contract
      })

    Forum.file_priority_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: "The cart never changed.",
        priority_amount_atomic: 5_000_000,
        payment_intent_id: Ash.UUID.generate()
      },
      actor: asker
    )
  end

  # The settlement path's own write, which no actor may reach.
  defp submitted(report, filed_at) do
    {:ok, submitted} =
      Forum.record_escrow_credit(
        report,
        %{escrow_status: :credit_submitted, escrow_credit_tx_hash: hash()},
        authorize?: false
      )

    Repo.query!("UPDATE forum_reports SET inserted_at = $1 WHERE id = $2", [
      filed_at,
      Ecto.UUID.dump!(submitted.id)
    ])

    Forum.get_report!(submitted.id, authorize?: false)
  end

  defp answered_run do
    payer = profile("payer")

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
    # The assist worker's own steps, which no actor may reach.
    {:ok, running} = Assist.start_run(run, authorize?: false)
    Assist.finish_run!(running, %{status: :finished, outcome: :reached}, authorize?: false)
  end

  # The operator node's answer to one eth_call, as Finch reports it.
  defp answer(status, body) do
    OperatorWallet.handle_request(
      [:finch, :request, :stop],
      %{duration: 1},
      %{
        name: Ethereumex.Finch,
        request: Finch.build(:post, "http://node.test", [], ~s({"method":"eth_call"})),
        result: {:ok, %Finch.Response{status: status, body: body}}
      },
      nil
    )
  end

  defp hash, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp value(name, labels) do
    Telemetry.scrape()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      with [series, number] <- String.split(line, " "),
           true <- series == name or String.starts_with?(series, name <> "{"),
           true <- Enum.all?(labels, &String.contains?(series, &1)) do
        {number, ""} = Float.parse(number)
        number
      else
        _ -> nil
      end
    end)
  end
end
