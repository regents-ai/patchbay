defmodule PatchbayWeb.PaymentsAPI.PaymentIntentController do
  @moduledoc """
  The three endpoints behind a paid action: prepare one, pay for it, and read
  it back. Each is one call into `PatchbayWeb.PaymentsAPI.Purchase`; what is
  here is the HTTP shape of its answers: the status codes, the x402 headers and the JSON.

  The payer is whoever the pipeline signed in, a page's profile or a
  SIWA-verified wallet, and never a value the request carries.

  A wallet author pays in x402 (`execute/2`): it is handed the terms and signs
  them itself. A page pays with the wallet its person signed in with
  (`pay/2`): the payments library writes the authorization that wallet signs,
  and only the signature comes back (`RegentPayments.WalletPayment`).
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.PaymentsAPI.Purchase
  alias RegentPayments.USDC
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
                    "goal, site_url and sign_in"

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
      context: %{browser_session_id: conn.assigns.forum_session_id}
    }

    case Purchase.execute(conn.assigns.current_profile, id, request) do
      {:error, failure} -> send_failure(conn, failure)
      answer -> send_answer(conn, answer)
    end
  end

  def complete(conn, %{"id" => id}) do
    case Purchase.complete(conn.assigns.current_profile, id) do
      {:applied, intent, receipt} ->
        json(conn, Purchase.completion_payload(intent, receipt))

      {:settled, intent, receipt} ->
        conn |> put_status(:accepted) |> json(Purchase.completion_payload(intent, receipt))

      {:settlement_pending, intent} ->
        conn |> put_status(:conflict) |> json(Purchase.completion_payload(intent, nil))

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  @doc """
  A page's payment. Unsigned, it answers with what the signed-in wallet is to
  sign, when the page has that wallet open; a payment that already went
  through is read back without any wallet. Signed, the signature must be that
  wallet's over what the payments library wrote, and only then is the payment
  verified and settled.
  """
  def pay(conn, %{"id" => id} = params) do
    case Purchase.pay(conn.assigns.current_profile, id, params, conn.assigns.forum_session_id) do
      {:review, waiting, review} ->
        conn
        |> put_status(:payment_required)
        |> json(%{status: "payment_required", payment_intent_id: waiting.id, review: review})

      {:wallet_unavailable, intent_id} ->
        send_wallet_refusal(
          conn,
          "wallet_unavailable",
          "The wallet you signed in with is not open on this page.",
          "Connect that wallet in this browser, then pay again.",
          %{payment_intent_id: intent_id}
        )

      {:wallet_mismatch, intent_id, note} ->
        send_wallet_refusal(
          conn,
          "wallet_mismatch",
          "Your wallet app has another wallet open.",
          "Switch your wallet app to the wallet you signed in with, then pay again.",
          %{payment_intent_id: intent_id, wallet_note: note}
        )

      {:payment_refused, intent_id, reason} ->
        send_wallet_refusal(
          conn,
          "payment_refused",
          reason,
          "Nothing was charged. Check the wallet, then pay again.",
          %{payment_intent_id: intent_id}
        )

      {:error, failure} ->
        send_failure(conn, failure)

      answer ->
        send_answer(conn, answer)
    end
  end

  # Not paid, with why the page's wallet cannot pay. No x402 terms go to a page.
  defp send_wallet_refusal(conn, code, message, hint, fields) do
    conn
    |> put_status(:payment_required)
    |> json(ApiError.body(code, message, hint, fields))
  end

  def show(conn, %{"id" => id}) do
    case RegentPayments.Purchase.read(conn.assigns.current_profile, id) do
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
        receipt: RegentPayments.Purchase.receipt_payload(receipt),
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

  # A payment that could not be applied is refused like anything else, with
  # the intent's id and the payment help inside the refusal.
  defp send_answer(conn, {:settlement_pending, found}) do
    conn
    |> put_status(:conflict)
    |> json(
      ApiError.body(
        "settlement_pending",
        "This payment is being confirmed with the payment service by hand.",
        "Do not pay again. Read the intent back until it settles.",
        Purchase.payment_help(%{status: "settlement_pending", payment_intent_id: found.id})
      )
    )
  end

  defp send_answer(conn, {:expired, found}) do
    conn
    |> put_status(:gone)
    |> json(
      ApiError.body(
        "expired",
        "These terms are no longer on offer.",
        "Ask for this again to be given fresh ones.",
        Purchase.payment_help(%{status: "expired", payment_intent_id: found.id})
      )
    )
  end

  defp send_answer(conn, {:facilitator_unavailable, found, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(
      ApiError.body(
        "facilitator_unavailable",
        "The payment service could not be reached.",
        "Do not pay again. Retry the same signed intent or check its status.",
        Purchase.payment_help(%{
          status: "facilitator_unavailable",
          payment_intent_id: found.id,
          reason: reason
        })
      )
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
    |> json(
      ApiError.body(
        "not_found",
        "There is no payment intent with that id.",
        "Check the id from the answer that created the intent."
      )
    )
  end

  defp send_failure(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(
      ApiError.body(
        "forbidden",
        "That payment intent belongs to someone else.",
        "Read only the intents this profile created."
      )
    )
  end

  defp send_failure(conn, :not_configured) do
    conn
    |> put_status(:service_unavailable)
    |> json(
      ApiError.body(
        "not_configured",
        @not_set_up,
        "Use the free Patchbay tools. Payments are not enabled on this deployment.",
        Purchase.payment_help(%{})
      )
    )
  end

  defp send_failure(conn, :assist_not_configured) do
    conn
    |> put_status(:service_unavailable)
    |> json(
      ApiError.body(
        "not_configured",
        @assist_not_set_up,
        "Use the free Patchbay tools. Paid assists are not enabled on this deployment.",
        Purchase.payment_help(%{})
      )
    )
  end

  defp send_failure(conn, {:assist_running, run, assist_url}) do
    conn
    |> put_status(:conflict)
    |> json(
      ApiError.body(
        "assist_running",
        "Patchbay is already working on an assist for you. Read it at assist_url; " <>
          "ask for another once it has answered. Nothing was charged.",
        "Read the assist at assist_url, and ask for another once it has answered.",
        %{run_id: run.id, assist_url: assist_url}
      )
    )
  end

  defp send_failure(conn, :needs_sign_in) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ApiError.body(
        "needs_sign_in",
        @needs_sign_in,
        "Ask about the site on the board instead, where other agents can help."
      )
    )
  end

  defp send_failure(conn, {:invalid, messages}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ApiError.invalid(messages))
  end

  defp send_failure(conn, %Ash.Error.Forbidden{}), do: send_failure(conn, :forbidden)

  defp send_failure(conn, error),
    do: send_failure(conn, {:invalid, Purchase.refusal_messages(error)})
end
