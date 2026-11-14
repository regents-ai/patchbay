defmodule Patchbay.Assist.ReceiptTest do
  @moduledoc """
  An assist's receipt, assembled from what Patchbay already keeps: a free
  assist and a paid one, the draft the model wrote, and the agent's own word
  on whether its retry passed, failed or is not reported yet. Verification
  is never claimed.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.AssistFixtures, only: [browser_run: 1, paid_run: 2]

  alias Patchbay.Assist
  alias Patchbay.Assist.KnownFixes
  alias Patchbay.Assist.ModelCalls
  alias Patchbay.Assist.Receipt
  alias Patchbay.Identity
  alias PatchbayWeb.KnownFixAnswer

  test "a free assist: free, no draft, nothing reported, not checked" do
    run = browser_run(%{})

    assert Receipt.for_run(run) == %{
             payment: %{paid: false},
             model: nil,
             suggested_action: %{known_fix: nil, call: nil},
             actual_call: nil,
             result: "not_reported",
             verification: "not_checked"
           }
  end

  test "a paid assist names the amount, the paying wallet and its transaction" do
    payer =
      Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("a", 40)})

    run = paid_run(payer, "0x" <> String.duplicate("d", 40))

    assert %{
             paid: true,
             payment_intent_id: intent_id,
             amount_usdc: "0.10",
             wallet: wallet,
             transaction: "0x" <> _hash
           } = Receipt.for_run(run).payment

    assert intent_id == run.payment_intent_id
    assert wallet == payer.wallet_address
  end

  test "the draft's provider, model, ids and usage, and the call it led to" do
    run = browser_run(%{})
    call = ModelCalls.ask(:draft_arguments, "z-ai/glm-5.3-flash", run.id, "near_ai")

    ModelCalls.close(
      call,
      {:ok, %{"usage" => %{"prompt_tokens" => 311, "completion_tokens" => 24}}},
      {"prompt_tokens", "completion_tokens"},
      %{response_id: "f47b46", request_id: "req-7f3a"}
    )

    run =
      step(run, %{
        "tool" => "find_table",
        "arguments" => %{"party" => 2},
        "call" => "suggested",
        "answer" => nil,
        "reading" => nil
      })

    receipt = Receipt.for_run(run)

    assert receipt.model == %{
             provider: "near_ai",
             model: "z-ai/glm-5.3-flash",
             outcome: :answered,
             response_id: "f47b46",
             request_id: "req-7f3a",
             prompt_tokens: 311,
             completion_tokens: 24
           }

    assert receipt.suggested_action.call == %{
             tool: "find_table",
             arguments: %{"party" => 2},
             called_by_patchbay: false
           }

    assert receipt.verification == "not_checked"
  end

  test "the agent's word on its retry: passed, failed, or not reported yet" do
    fix = hd(KnownFixes.all())

    for {said, result} <- [
          {"worked", "passed"},
          {"did_not_work", "failed"},
          {nil, "not_reported"}
        ] do
      run = browser_run(%{})

      decision =
        Assist.record_decision!(
          %{
            site: "bookings.example.com",
            asked_from: :fix,
            assist_run_id: run.id,
            choice: fix.id,
            confidence: 0.8,
            model: "jev-test"
          },
          authorize?: false
        )

      run =
        step(run, %{
          "known_fix" => %{"decision_id" => decision.id, "fix" => fix.id, "confidence" => 0.8},
          "note" => "Jev matched a known fix."
        })

      if said, do: {:ok, _recorded} = KnownFixAnswer.report(decision.id, said)

      receipt = Receipt.for_run(run)
      assert receipt.result == result
      assert receipt.suggested_action.known_fix == fix.title
      assert receipt.actual_call == nil
      assert receipt.verification == "not_checked"
    end
  end

  # The worker's own step on its own run.
  defp step(run, step) do
    {:ok, running} = Assist.start_run(run, authorize?: false)
    Assist.record_step!(running, step, authorize?: false)
  end
end
