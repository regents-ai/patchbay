defmodule PatchbayWeb.PaymentsAPI.PaymentIntentController do
  @moduledoc """
  The endpoints behind a paid action: prepare one, pay for it, finish one
  already paid, and read it back. Each is one call into
  `PatchbayWeb.PaymentsAPI.Purchase`; what is here is the shape of its
  answers: the status codes, the x402 headers and the JSON. The hosted tools
  at `/mcp` answer with the same bodies (`PatchbayWeb.MCP.Doors`), and a
  page's tools send the same signed requests.

  The payer is whoever the pipeline signed in, a page's profile or a
  SIWA-verified, paired agent, and never a value the request carries.

  An agent pays in x402 from its own wallet (`execute/2`): it is handed the
  terms and signs them with its own key; Patchbay never holds or uses it. A page pays with the wallet its person signed in with
  (`pay/2`): the payments library writes the authorization that wallet signs,
  and only the signature comes back (`RegentPayments.WalletPayment`).
  """

  use PatchbayWeb, :controller

  alias Patchbay.Agents.Actor
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

  def create(conn, params) do
    respond(conn, prepare(conn.assigns.current_profile, params, conn.assigns.forum_session_id))
  end

  def execute(conn, %{"id" => id}) do
    %{current_profile: actor, forum_session_id: browser_session_id} = conn.assigns
    respond(conn, execute_payment(actor, id, payment_signature(conn), browser_session_id))
  end

  def complete(conn, %{"id" => id}),
    do: respond(conn, complete_payment(conn.assigns.current_profile, id))

  def show(conn, %{"id" => id}),
    do: respond(conn, payment_status(conn.assigns.current_profile, id))

  # Every agent payment door answers with one of these, as a status, the
  # headers that go with it and the body: `POST /api/agent/payment_intents`
  # and its `execute`, `complete` and read addresses, the page tools that
  # send those requests, and the hosted tools at `/mcp`
  # (`PatchbayWeb.MCP.Doors`), which take the body alone.

  @typedoc "A door's answer: its status, the headers that go with it and its body."
  @type answer :: {atom(), [{String.t(), String.t()}], map()}

  @doc """
  Freezes the terms `params` ask for (`kind` and `args`) for `actor`, from
  the browser `browser_session_id` names, if any. The payer is `actor`,
  never a value the request carries.
  """
  @spec prepare(struct(), map(), Ash.UUID.t() | nil) :: answer()
  # An agent could not award or withdraw the bounty of a priority report it
  # paid for, so agents get none until they can (PB-17 hold).
  def prepare(%Actor{}, %{"kind" => "special_post"}, _browser_session_id),
    do: failure(:agent_reports_held)

  def prepare(actor, %{"kind" => "agent_tip", "args" => %{} = args}, _browser_session_id),
    do: actor |> Purchase.prepare_agent_tip(args) |> created()

  def prepare(actor, %{"kind" => "special_post", "args" => %{} = args}, _browser_session_id),
    do: actor |> Purchase.prepare_special_post(args) |> created()

  def prepare(actor, %{"kind" => "jev_assist", "args" => %{} = args}, browser_session_id),
    do: actor |> Purchase.prepare_jev_assist(args, browser_session_id) |> created()

  def prepare(_actor, _params, _browser_session_id), do: failure({:invalid, [@unknown_action]})

  defp created({:ok, intent}), do: {:created, [], Purchase.intent_payload(intent)}
  defp created({:error, reason}), do: failure(reason)

  @doc """
  Moves `actor`'s intent `id` one step on: with no `payment`, the x402 terms
  to sign; with the signed payment (the encoded x402 payment), the payment
  checked against those terms, settled at most once and carried out. The
  wallet it must come from is the one the terms froze for `actor`.
  `browser_session_id` is the identity the purchase is filed under.
  """
  @spec execute_payment(struct(), String.t(), String.t() | nil, Ash.UUID.t() | nil) :: answer()
  def execute_payment(actor, id, payment, browser_session_id) do
    request = %{payment: payment, payer: nil, context: %{browser_session_id: browser_session_id}}

    if held?(actor, id),
      do: failure(:agent_reports_held),
      else: actor |> Purchase.execute(id, request) |> executed()
  end

  defp executed({:error, reason}), do: failure(reason)
  defp executed(answer), do: paid(answer)

  # Priority report terms an agent prepared before the hold are not paid
  # now; one already paid is still finished and read back.
  defp held?(%Actor{} = actor, id) do
    match?(
      {:ok, %{kind: :special_post, status: status}} when status in [:prepared, :payment_required],
      RegentPayments.Purchase.read(actor, id)
    )
  end

  defp held?(_actor, _id), do: false

  @doc "Finishes `actor`'s already authorized intent `id`; it never starts or retries a payment."
  @spec complete_payment(struct(), String.t()) :: answer()
  def complete_payment(actor, id) do
    case Purchase.complete(actor, id) do
      {:applied, intent, receipt} -> {:ok, [], Purchase.completion_payload(intent, receipt)}
      {:settled, intent, receipt} -> {:accepted, [], Purchase.completion_payload(intent, receipt)}
      {:settlement_pending, intent} -> {:conflict, [], Purchase.completion_payload(intent, nil)}
      {:error, reason} -> failure(reason)
    end
  end

  @doc "`actor`'s intent `id` as it stands, with its receipt and effect once paid. Never pays."
  @spec payment_status(struct(), String.t()) :: answer()
  def payment_status(actor, id) do
    case RegentPayments.Purchase.read(actor, id) do
      {:ok, found} ->
        {:ok, [], Map.merge(Purchase.intent_payload(found), Purchase.recovery_payload(found))}

      {:error, reason} ->
        failure(reason)
    end
  end

  defp respond(conn, {status, headers, body}) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> put_status(status)
    |> json(body)
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
        respond(
          conn,
          {:payment_required, [],
           %{status: "payment_required", payment_intent_id: waiting.id, review: review}}
        )

      {:wallet_unavailable, intent_id} ->
        send_wallet_refusal(
          conn,
          "wallet_unavailable",
          "The wallet you signed in with is not open on this page.",
          "Open that wallet in your wallet app, then pay again.",
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

      {:error, reason} ->
        respond(conn, failure(reason))

      answer ->
        respond(conn, paid(answer))
    end
  end

  # Not paid, with why the page's wallet cannot pay. No x402 terms go to a page.
  defp send_wallet_refusal(conn, code, message, hint, fields),
    do: respond(conn, {:payment_required, [], ApiError.body(code, message, hint, fields)})

  defp payment_signature(conn) do
    case get_req_header(conn, "payment-signature") do
      [value | _rest] when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  # Answers

  defp paid({:payment_required, found}),
    do: offered(found, Purchase.terms(found, @challenge_error))

  # A payment sent and refused is a refusal, with the terms to sign again
  # inside it. Nothing was paid.
  defp paid({:payment_rejected, found, reason}) do
    terms = Purchase.terms(found, reason)
    {:ok, header} = PaymentRequired.encode(terms)

    {:payment_required, [{"payment-required", header}],
     ApiError.body(
       "payment_refused",
       reason,
       "Nothing was paid. Sign payment_terms with your own wallet, then send them again.",
       Purchase.payment_help(%{
         status: "payment_required",
         payment_intent_id: found.id,
         payment_terms: terms
       })
     )}
  end

  defp paid({:applied, found, receipt}) do
    {:ok, header} = PaymentResponse.encode(receipt.payment_response)

    answer =
      Purchase.payment_help(%{
        status: "applied",
        payment_intent_id: found.id,
        receipt: RegentPayments.Purchase.receipt_payload(receipt),
        amount_usdc: USDC.format(found.amount_atomic),
        effect_summary: found.effect_summary
      })

    {:ok, [{"payment-response", header}], Map.merge(answer, Purchase.applied_effect(found))}
  end

  defp paid({:settled, found, receipt}) do
    {:accepted, [],
     Purchase.intent_payload(found)
     |> Map.merge(Purchase.recovery_payload(%{found | receipt: receipt}))
     |> Map.put(:payment_intent_id, found.id)}
  end

  # A payment that could not be applied is refused like anything else, with
  # the intent's id and the payment help inside the refusal.
  defp paid({:settlement_pending, found}) do
    {:conflict, [],
     ApiError.body(
       "settlement_pending",
       "This payment is being confirmed with the payment service by hand.",
       "Do not pay again. Read the intent back until it settles.",
       Purchase.payment_help(%{status: "settlement_pending", payment_intent_id: found.id})
     )}
  end

  defp paid({:expired, found}) do
    {:gone, [],
     ApiError.body(
       "expired",
       "These terms are no longer on offer.",
       "Ask for this again to be given fresh ones.",
       Purchase.payment_help(%{status: "expired", payment_intent_id: found.id})
     )}
  end

  defp paid({:facilitator_unavailable, found, reason}) do
    {:bad_gateway, [],
     ApiError.body(
       "facilitator_unavailable",
       "The payment service could not be reached.",
       "Do not pay again. Retry the same signed intent or check its status.",
       Purchase.payment_help(%{
         status: "facilitator_unavailable",
         payment_intent_id: found.id,
         reason: reason
       })
     )}
  end

  # The x402 terms, in the PAYMENT-REQUIRED header and in the body alike.
  defp offered(found, terms) do
    {:ok, header} = PaymentRequired.encode(terms)

    {:payment_required, [{"payment-required", header}],
     Purchase.payment_help(%{
       status: "payment_required",
       payment_intent_id: found.id,
       payment_terms: terms,
       next_action: @pay_and_retry
     })}
  end

  # Refusals

  defp failure(:not_found) do
    {:not_found, [],
     ApiError.body(
       "not_found",
       "There is no payment intent with that id.",
       "Check the id from the answer that created the intent."
     )}
  end

  defp failure(:agent_reports_held) do
    {:forbidden, [],
     ApiError.body(
       "agent_reports_held",
       "Agents can't post paid priority questions yet: they couldn't award or withdraw the bounty. Nothing was charged.",
       "Ask for free with ask_question (regents patchbay threads create), or buy a paid assist with request_assist."
     )}
  end

  defp failure(:forbidden) do
    {:forbidden, [],
     ApiError.body(
       "forbidden",
       "That payment intent belongs to someone else.",
       "Read only the intents this profile created."
     )}
  end

  defp failure(:not_configured) do
    {:service_unavailable, [],
     ApiError.body(
       "not_configured",
       @not_set_up,
       "Use the free Patchbay tools. Payments are not enabled on this deployment.",
       Purchase.payment_help(%{})
     )}
  end

  defp failure(:assist_not_configured) do
    {:service_unavailable, [],
     ApiError.body(
       "not_configured",
       @assist_not_set_up,
       "Use the free Patchbay tools. Paid assists are not enabled on this deployment.",
       Purchase.payment_help(%{})
     )}
  end

  defp failure({:assist_running, run, assist_url}) do
    {:conflict, [],
     ApiError.body(
       "assist_running",
       "Patchbay is already working on an assist for you. Read it at assist_url; " <>
         "ask for another once it has answered. Nothing was charged.",
       "Read the assist at assist_url, and ask for another once it has answered.",
       %{run_id: run.id, assist_url: assist_url}
     )}
  end

  defp failure(:needs_sign_in) do
    {:unprocessable_entity, [],
     ApiError.body(
       "needs_sign_in",
       @needs_sign_in,
       "Ask about the site on the board instead, where other agents can help."
     )}
  end

  defp failure({:invalid, messages}), do: {:unprocessable_entity, [], ApiError.invalid(messages)}

  # A paid priority report is read like any other post before it is priced;
  # these are that reading's refusals. Nothing was charged.
  defp failure({:post_rejected, message, details}) do
    {:unprocessable_entity, [],
     ApiError.body(
       "post_rejected",
       message,
       "Rewrite the report with what you tried, what happened and what you expected, then send it again.",
       details
     )}
  end

  defp failure({:posting_paused, message, until}) do
    seconds = max(DateTime.diff(until, DateTime.utc_now()), 1)

    {:forbidden, [{"retry-after", Integer.to_string(seconds)}],
     ApiError.body("posting_paused", message, "Post again after posting_paused_until.", %{
       posting_paused_until: until
     })}
  end

  defp failure({:rate_limited, :account, message, seconds}) do
    {:too_many_requests, [{"retry-after", Integer.to_string(seconds)}],
     ApiError.body("rate_limited", message, "Wait retry_after_seconds, then send it again.", %{
       subject: "account",
       retry_after_seconds: seconds
     })}
  end

  defp failure({:unavailable, words}),
    do:
      {:service_unavailable, [],
       ApiError.body("unavailable", words, "Try the same call again in a moment.")}

  defp failure(%Ash.Error.Forbidden{}), do: failure(:forbidden)

  defp failure(error), do: failure({:invalid, Purchase.refusal_messages(error)})
end
