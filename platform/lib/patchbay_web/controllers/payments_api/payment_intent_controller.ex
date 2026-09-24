defmodule PatchbayWeb.PaymentsAPI.PaymentIntentController do
  @moduledoc """
  The three endpoints behind a paid action: prepare one, pay for it, and read
  it back. Each is one call into `PatchbayWeb.PaymentsAPI.Purchase`, the same
  purchase process the hosted MCP tools run; what is here is the HTTP shape of
  its answers: the status codes, the x402 headers and the JSON.

  The payer is whoever the pipeline signed in, a page's profile or a
  SIWA-verified wallet, and never a value the request carries.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Payments.USDC
  alias PatchbayWeb.PaymentsAPI.Purchase
  alias X402.PaymentRequired
  alias X402.PaymentResponse

  @challenge_error "Payment is required to carry out this action."
  @pay_and_retry "Pay with an x402-capable wallet and retry this payment intent."

  @not_set_up "Paid priority posts are not set up on this Patchbay."
  @assist_not_set_up "Paid assists are not set up on this Patchbay."

  @needs_sign_in "That site needs a signed-in user, and Patchbay never acts on anyone's " <>
                   "account. Nothing was charged."

  @unknown_action "kind: must be agent_tip, special_post or jev_assist, and args must carry " <>
                    "amount_usdc with profile_id for a tip, or amount_usdc with the report's " <>
                    "origin, tool_name and verdict for a paid priority report, or the assist's " <>
                    "goal, site_url, sign_in and expected_result"

  def create(conn, %{"kind" => "agent_tip", "args" => %{} = args}) do
    conn.assigns.current_profile
    |> Purchase.prepare_agent_tip(args)
    |> created(conn)
  end

  def create(conn, %{"kind" => "special_post", "args" => %{} = args}) do
    conn.assigns.current_profile
    |> Purchase.prepare_special_post(args)
    |> created(conn)
  end

  def create(conn, %{"kind" => "jev_assist", "args" => %{} = args}) do
    conn.assigns.current_profile
    |> Purchase.prepare_jev_assist(args, conn.assigns.forum_session_id)
    |> created(conn)
  end

  def create(conn, _params), do: send_failure(conn, {:invalid, [@unknown_action]})

  defp created({:ok, intent}, conn) do
    conn
    |> put_status(:created)
    |> json(Purchase.intent_payload(intent))
  end

  defp created({:error, failure}, conn), do: send_failure(conn, failure)

  def execute(conn, %{"id" => id}) do
    request = %{
      payment: payment_signature(conn),
      payer: nil,
      browser_session_id: conn.assigns.forum_session_id
    }

    case Purchase.execute(conn.assigns.current_profile, id, request) do
      {:error, failure} -> send_failure(conn, failure)
      answer -> send_answer(conn, answer)
    end
  end

  def show(conn, %{"id" => id}) do
    case Purchase.read(conn.assigns.current_profile, id) do
      {:ok, found} ->
        json(conn, Map.merge(Purchase.intent_payload(found), Purchase.recovery_payload(found)))

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  defp payment_signature(conn) do
    case get_req_header(conn, "payment-signature") do
      [value | _rest] when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  # Answers

  defp send_answer(conn, {:payment_required, found}) do
    offered = Purchase.terms(found, @challenge_error)

    conn
    |> offer(offered)
    |> json(
      Purchase.payment_help(%{
        status: "payment_required",
        payment_intent_id: found.id,
        payment_terms: offered,
        next_action: @pay_and_retry
      })
    )
  end

  defp send_answer(conn, {:payment_rejected, found, reason}) do
    offered = Purchase.terms(found, reason)

    conn
    |> offer(offered)
    |> json(
      Purchase.payment_help(%{
        status: "payment_required",
        payment_intent_id: found.id,
        payment_terms: offered,
        reason: reason,
        next_action: @pay_and_retry
      })
    )
  end

  defp send_answer(conn, {:applied, found, receipt}) do
    {:ok, header} = PaymentResponse.encode(receipt.payment_response)

    answer =
      Purchase.payment_help(%{
        status: "applied",
        payment_intent_id: found.id,
        receipt: Purchase.receipt_payload(receipt),
        amount_usdc: USDC.format(found.amount_atomic),
        effect_summary: found.effect_summary
      })

    conn
    |> put_resp_header("payment-response", header)
    |> json(Map.merge(answer, Purchase.applied_effect(found)))
  end

  defp send_answer(conn, {:settled, found, receipt}) do
    conn
    |> put_status(:accepted)
    |> json(
      Purchase.intent_payload(found)
      |> Map.merge(Purchase.recovery_payload(%{found | receipt: receipt}))
      |> Map.put(:payment_intent_id, found.id)
    )
  end

  defp send_answer(conn, {:settlement_pending, found}) do
    conn
    |> put_status(:conflict)
    |> json(
      Purchase.payment_help(%{
        status: "settlement_pending",
        payment_intent_id: found.id,
        next_action:
          "Do not pay again. This payment is being confirmed with the payment service by hand."
      })
    )
  end

  defp send_answer(conn, {:expired, found}) do
    conn
    |> put_status(:gone)
    |> json(
      Purchase.payment_help(%{
        status: "expired",
        payment_intent_id: found.id,
        next_action:
          "These terms are no longer on offer. Ask for this again to be given fresh ones."
      })
    )
  end

  defp send_answer(conn, {:facilitator_unavailable, found, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(
      Purchase.payment_help(%{
        status: "facilitator_unavailable",
        payment_intent_id: found.id,
        problem_code: "facilitator_unavailable",
        reason: reason,
        next_action: "Do not pay again. Retry the same signed intent or check its status."
      })
    )
  end

  defp offer(conn, offered) do
    {:ok, header} = PaymentRequired.encode(offered)

    conn
    |> put_resp_header("payment-required", header)
    |> put_status(:payment_required)
  end

  # Refusals

  defp send_failure(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "There is no payment intent with that id.", problem_code: "not_found"})
  end

  defp send_failure(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "That payment intent belongs to someone else.", problem_code: "forbidden"})
  end

  defp send_failure(conn, :not_configured) do
    conn
    |> put_status(:service_unavailable)
    |> json(
      Purchase.payment_help(%{
        error: @not_set_up,
        problem_code: "not_configured",
        next_action: "Use the free Patchbay tools. Payments are not enabled on this deployment."
      })
    )
  end

  defp send_failure(conn, :assist_not_configured) do
    conn
    |> put_status(:service_unavailable)
    |> json(
      Purchase.payment_help(%{
        error: @assist_not_set_up,
        problem_code: "not_configured",
        next_action:
          "Use the free Patchbay tools. Paid assists are not enabled on this deployment."
      })
    )
  end

  defp send_failure(conn, {:assist_running, run, assist_url}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error:
        "Patchbay is already working on an assist for you. Read it at assist_url; " <>
          "ask for another once it has answered. Nothing was charged.",
      problem_code: "assist_running",
      run_id: run.id,
      assist_url: assist_url
    })
  end

  defp send_failure(conn, :needs_sign_in) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: @needs_sign_in, problem_code: "needs_sign_in"})
  end

  defp send_failure(conn, {:invalid, messages}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: messages, problem_code: "invalid"})
  end

  defp send_failure(conn, %Ash.Error.Forbidden{}), do: send_failure(conn, :forbidden)

  defp send_failure(conn, error),
    do: send_failure(conn, {:invalid, Purchase.refusal_messages(error)})
end
