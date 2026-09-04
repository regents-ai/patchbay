defmodule PatchbayWeb.PaymentsAPI.PaymentIntentController do
  @moduledoc """
  The three endpoints behind a paid action: prepare one, pay for it, and read
  it back.

  Preparing an action freezes what it will cost and who receives the money.
  Executing it hands back the x402 terms to sign, and then, once a signature
  arrives, checks that signature against those same frozen terms before any
  money moves. Nothing the caller sends can change the amount or the
  destination after the fact: the terms are read from the stored intent every
  time, never from the request.

  The money never passes through Patchbay. The payer's wallet pays the wallet
  the terms name, a profile's own for a tip and the escrow contract for a paid
  priority report, a payment service verifies and settles it, and what is
  stored here is the record of what was promised and what happened. What the
  money bought is then carried out per kind: a tip is complete once settled,
  and a paid priority report is published from its frozen terms.

  One intent applies exactly once. The row is locked for the whole of an
  execute call, so two calls racing each other cannot both settle it, and a
  call that arrives after the effect was applied is answered with the stored
  result rather than charged again.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool
  alias Patchbay.Identity
  alias Patchbay.Payments
  alias Patchbay.Payments.PaymentIntent
  alias Patchbay.Payments.PaymentReceipt
  alias Patchbay.Payments.SpecialPost
  alias Patchbay.Payments.USDC
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.ForumAPI.Refusal
  alias X402.Extensions.PaymentIdentifier
  alias X402.Facilitator
  alias X402.PaymentRequired
  alias X402.PaymentResponse
  alias X402.PaymentSignature
  alias X402.Scheme.ExactEVM

  # The registered name of the payment service client, configured in
  # config/runtime.exs and started with the application.
  @facilitator Patchbay.Payments.Facilitator

  # How long the payment service may take to settle a signed payment. It is
  # advertised in the terms, so a wallet knows what window it is signing for.
  @max_timeout_seconds 300

  @challenge_error "Payment is required to carry out this action."
  @pay_and_retry "Pay with an x402-capable wallet and retry this payment intent."
  @generic_failure "That could not be done. Check the values you sent and try again."

  @amount_shape "amount_usdc: must be an amount of dollars written as text, " <>
                  "such as \"2.00\", with at most six decimal places"

  @profile_shape "profile_id: must be the public id of the profile being paid, such as \"agt_2f9c1d\""

  @unknown_profile "profile_id: there is no profile with that id"

  @not_set_up "Paid priority posts are not set up on this Patchbay."

  @unknown_action "kind: must be agent_tip or special_post, and args must carry amount_usdc " <>
                    "with profile_id for a tip, or with the report's origin, tool_name and verdict " <>
                    "for a paid priority report"

  def create(conn, %{"kind" => "agent_tip", "args" => %{} = args}) do
    actor = conn.assigns.current_profile

    with {:ok, amount_atomic} <- amount(args),
         {:ok, recipient} <- tip_recipient(args),
         {:ok, intent} <- Payments.prepare_agent_tip(tip(recipient, amount_atomic), actor: actor) do
      created(conn, intent)
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def create(conn, %{"kind" => "special_post", "args" => %{} = args}) do
    actor = conn.assigns.current_profile

    with :ok <- escrow_set_up(),
         {:ok, amount_atomic} <- amount(args),
         {:ok, draft} <- OtherSiteReport.draft(Map.delete(args, "amount_usdc")),
         {:ok, intent} <- prepare_special_post(actor, draft, amount_atomic) do
      created(conn, intent)
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def create(conn, _params), do: send_failure(conn, {:invalid, [@unknown_action]})

  defp created(conn, intent) do
    conn
    |> put_status(:created)
    |> json(intent_payload(intent))
  end

  def execute(conn, %{"id" => id}) do
    actor = conn.assigns.current_profile

    case under_lock(actor, id, request(conn)) do
      {:error, failure} -> send_failure(conn, failure)
      answer -> send_answer(conn, answer)
    end
  end

  def show(conn, %{"id" => id}) do
    actor = conn.assigns.current_profile

    case intent(actor, id, &Payments.get_payment_intent/2) do
      {:ok, found} -> json(conn, intent_payload(found))
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  # Preparing a payment

  defp amount(%{"amount_usdc" => written}) when is_binary(written) do
    case USDC.parse(written) do
      {:ok, amount_atomic} -> {:ok, amount_atomic}
      :error -> {:error, {:invalid, [@amount_shape]}}
    end
  end

  defp amount(_args), do: {:error, {:invalid, [@amount_shape]}}

  defp tip(recipient, amount_atomic), do: %{recipient: recipient, amount_atomic: amount_atomic}

  defp tip_recipient(%{"profile_id" => public_id}) when is_binary(public_id) do
    case found_or_missing(Identity.get_profile_by_public_id(public_id)) do
      {:ok, recipient} -> {:ok, recipient}
      {:error, :not_found} -> {:error, {:invalid, [@unknown_profile]}}
      {:error, failure} -> {:error, failure}
    end
  end

  defp tip_recipient(_args), do: {:error, {:invalid, [@profile_shape]}}

  defp escrow_set_up do
    if Escrow.contract_address(), do: :ok, else: {:error, :not_configured}
  end

  # The site and the tool the draft names are registered alongside the terms,
  # so a draft that is refused leaves no empty board behind it. The draft
  # itself is checked by the terms' own action, against the forum's rules,
  # before anything is written.
  defp prepare_special_post(actor, draft, amount_atomic) do
    case Ash.transact([Site, Tool, PaymentIntent], fn -> frozen(actor, draft, amount_atomic) end) do
      {:ok, {:ok, intent}} -> {:ok, intent}
      {:error, failure} -> {:error, failure}
    end
  end

  defp frozen(actor, draft, amount_atomic) do
    with {:ok, tool} <- OtherSiteReport.resolve_tool(draft) do
      Payments.prepare_special_post(
        %{tool: tool, draft: draft, amount_atomic: amount_atomic},
        actor: actor
      )
    end
  end

  # Executing a payment intent

  # What an execute call carries besides the intent's id: the signature, if
  # the payer has signed, and the browser's forum identity, which is what a
  # report paid for here is filed under.
  defp request(conn) do
    %{signature: payment_signature(conn), browser_session_id: conn.assigns.forum_session_id}
  end

  # The whole of an execute call happens under one row lock, so a settled
  # intent is applied exactly once however many calls arrive at once.
  defp under_lock(actor, id, request) do
    case Ash.transact([PaymentIntent, PaymentReceipt], fn -> attempt(actor, id, request) end) do
      {:ok, {:settled, answer}} -> answer
      {:error, failed_write} -> {:error, failed_write}
    end
  end

  # A refusal is an answer, and the status it wrote down travels out with it.
  # Only a write that genuinely failed undoes the transaction.
  defp attempt(actor, id, request) do
    case locked(actor, id, request) do
      {:error, failure} when is_exception(failure) -> {:error, failure}
      answer -> {:settled, answer}
    end
  end

  defp locked(actor, id, request) do
    case intent(actor, id, &Payments.lock_payment_intent/2) do
      {:ok, found} -> advance(actor, found, request)
      {:error, failure} -> {:error, failure}
    end
  end

  defp advance(_actor, %{status: status} = found, _request)
       when status in [:settled, :applied] do
    {:applied, found, found.receipt}
  end

  defp advance(_actor, %{status: :settlement_pending} = found, _request) do
    {:settlement_pending, found}
  end

  defp advance(actor, found, request) do
    if DateTime.before?(found.expires_at, DateTime.utc_now()) do
      expire(actor, found)
    else
      offer_or_settle(actor, found, request)
    end
  end

  defp expire(actor, found) do
    case Payments.expire_payment_intent(found, actor: actor) do
      {:ok, expired} -> {:expired, expired}
      {:error, failure} -> {:error, failure}
    end
  end

  defp offer_or_settle(actor, found, %{signature: nil}) do
    case Payments.mark_payment_required(found, actor: actor) do
      {:ok, waiting} -> {:payment_required, waiting}
      {:error, failure} -> {:error, failure}
    end
  end

  defp offer_or_settle(actor, found, request) do
    requirement = requirement(found)

    case checked_payment(request.signature, found, requirement) do
      {:ok, payment} -> settle(actor, found, payment, requirement, request)
      {:refused, reason} -> {:payment_rejected, found, reason}
      {:unavailable, reason} -> {:facilitator_unavailable, found, reason}
    end
  end

  # Checking a signature against the frozen terms

  defp checked_payment(signature, found, requirement) do
    with {:ok, payment} <- decoded(signature, requirement),
         :ok <- names_this_intent(payment, found),
         :ok <- prechecked(payment, requirement),
         :ok <- verified(payment, requirement) do
      {:ok, payment}
    end
  end

  # Decoding matches the signed `accepted` terms against this intent's own
  # requirement field for field, so a signature made for any other amount,
  # asset, network or wallet is refused before anything else happens.
  defp decoded(signature, requirement) do
    case PaymentSignature.decode_and_validate(signature, requirement) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, :no_matching_requirements} ->
        {:refused, "That payment was signed for different terms than this payment intent's."}

      {:error, _reason} ->
        {:refused, "That payment signature could not be read as an x402 version 2 payment."}
    end
  end

  defp names_this_intent(payment, found) do
    case echoed_identifier(payment) do
      :absent -> :ok
      {:ok, identifier} -> matching_identifier(identifier, found.payment_identifier)
      :error -> {:refused, "The payment identifier in that signature could not be read."}
    end
  end

  defp matching_identifier(identifier, identifier), do: :ok

  defp matching_identifier(_identifier, _expected),
    do: {:refused, "That payment signature names a different payment."}

  defp echoed_identifier(payment) do
    case get_in(payment, ["extensions", "paymentIdentifier"]) do
      nil -> :absent
      encoded when is_binary(encoded) -> decoded_identifier(encoded)
      _other -> :error
    end
  end

  defp decoded_identifier(encoded) do
    case PaymentIdentifier.decode(encoded) do
      {:ok, identifier} -> {:ok, identifier}
      {:error, _reason} -> :error
    end
  end

  # The local check of the signed authorization: the wallet it pays, the exact
  # amount, and the window it is valid for.
  defp prechecked(payment, requirement) do
    case ExactEVM.precheck(payment, requirement, []) do
      :ok -> :ok
      {:error, {:precheck_failed, reason}} -> {:refused, precheck_message(reason)}
    end
  end

  defp precheck_message(:pay_to_mismatch),
    do: "That payment pays a different wallet than these terms."

  defp precheck_message(:amount_mismatch),
    do: "That payment is for a different amount than these terms."

  defp precheck_message(:authorization_expired),
    do: "That payment authorization has already expired."

  defp precheck_message(:authorization_not_yet_valid),
    do: "That payment authorization is not valid yet."

  defp precheck_message(_reason), do: "That payment authorization could not be read."

  defp verified(payment, requirement) do
    case Facilitator.verify(@facilitator, payment, requirement) do
      {:ok, %{status: status, body: %{"isValid" => true}}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: %{"isValid" => false} = body}} when status in 200..299 ->
        {:refused, invalid_message(body)}

      _unclear ->
        {:unavailable,
         "The payment service could not be reached before a settlement result."}
    end
  end

  defp invalid_message(%{"invalidReason" => reason}) when is_binary(reason) do
    "The payment service would not accept that payment: #{reason}."
  end

  defp invalid_message(_body), do: "The payment service would not accept that payment."

  # Settling

  defp settle(actor, found, payment, requirement, request) do
    case Facilitator.settle(@facilitator, payment, requirement) do
      {:ok, %{status: status, body: %{"success" => true} = body}} when status in 200..299 ->
        apply_payment(actor, found, payment, body, request)

      {:ok, %{status: status, body: %{"success" => false} = body}} when status in 200..299 ->
        refused_settlement(actor, found, body)

      _unclear ->
        hold(actor, found)
    end
  end

  # A payment service that has not finished settling may still move the money,
  # so nothing here retries or refuses it. A person reconciles it by hand.
  defp refused_settlement(actor, found, %{"errorReason" => "settlement_pending"}) do
    hold(actor, found)
  end

  defp refused_settlement(actor, found, body) do
    case Payments.mark_payment_failed(found, actor: actor) do
      {:ok, failed} -> {:payment_rejected, failed, settlement_message(body)}
      {:error, failure} -> {:error, failure}
    end
  end

  defp settlement_message(%{"errorReason" => reason}) when is_binary(reason) do
    "The payment service could not settle that payment: #{reason}."
  end

  defp settlement_message(_body), do: "The payment service could not settle that payment."

  defp hold(actor, found) do
    case Payments.mark_settlement_pending(found, actor: actor) do
      {:ok, pending} -> {:settlement_pending, pending}
      {:error, failure} -> {:error, failure}
    end
  end

  defp apply_payment(actor, found, payment, body, request) do
    with {:ok, receipt} <- record_receipt(actor, found, payment, body),
         {:ok, settled} <- Payments.mark_settled(found, actor: actor),
         {:ok, _effect} <- carry_out(settled, receipt, actor, request),
         {:ok, applied} <- Payments.mark_applied(settled, actor: actor) do
      {:applied, applied, receipt}
    end
  end

  # What the money bought. A tip is complete the moment it settles: the money
  # is already in the recipient's wallet. A paid priority report is published
  # from its frozen terms and the settled money is recorded against it.
  defp carry_out(%{kind: :agent_tip}, _receipt, _actor, _request), do: {:ok, :settled}

  defp carry_out(%{kind: :special_post} = settled, receipt, actor, request) do
    SpecialPost.publish(settled, receipt,
      actor: actor,
      browser_session_id: request.browser_session_id
    )
  end

  defp record_receipt(actor, found, payment, body) do
    Payments.record_payment_receipt(
      %{
        payment_intent_id: found.id,
        payment_identifier: found.payment_identifier,
        payer_address: get_in(payment, ["payload", "authorization", "from"]),
        network: found.network,
        asset: found.asset,
        amount_atomic: found.amount_atomic,
        facilitator: facilitator_url(),
        transaction_hash: transaction_hash(body),
        payment_response: body,
        settled_at: DateTime.utc_now()
      },
      actor: actor
    )
  end

  defp transaction_hash(%{"transaction" => hash}) when is_binary(hash) and hash != "", do: hash
  defp transaction_hash(_body), do: nil

  defp facilitator_url do
    :patchbay |> Application.get_env(@facilitator, []) |> Keyword.fetch!(:url)
  end

  # The terms

  defp terms(found, error) do
    %{
      "x402Version" => 2,
      "error" => error,
      "resource" => %{
        "url" => execute_url(found),
        "description" => found.effect_summary,
        "mimeType" => "application/json"
      },
      "accepts" => [requirement(found)],
      "extensions" => %{"paymentIdentifier" => identifier_extension(found)}
    }
  end

  # Read from the stored intent every time, so what a payer signs for is what
  # was frozen when the intent was prepared.
  defp requirement(found) do
    %{
      "scheme" => "exact",
      "network" => found.network,
      "amount" => Integer.to_string(found.amount_atomic),
      "asset" => found.asset,
      "payTo" => Map.fetch!(found.payload, "pay_to_address"),
      "maxTimeoutSeconds" => @max_timeout_seconds,
      "extra" => USDC.signing_domain()
    }
  end

  defp identifier_extension(found) do
    {:ok, encoded} = PaymentIdentifier.encode(found.payment_identifier)
    encoded
  end

  # Answers

  defp send_answer(conn, {:payment_required, found}) do
    offered = terms(found, @challenge_error)

    conn
    |> offer(offered)
    |> json(
      with_payment_help(%{
        status: "payment_required",
        payment_intent_id: found.id,
        payment_terms: offered,
        next_action: @pay_and_retry
      })
    )
  end

  defp send_answer(conn, {:payment_rejected, found, reason}) do
    offered = terms(found, reason)

    conn
    |> offer(offered)
    |> json(
      with_payment_help(%{
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
      with_payment_help(%{
        status: "applied",
        payment_intent_id: found.id,
        receipt: %{
          transaction_hash: receipt.transaction_hash,
          payer_address: receipt.payer_address,
          settled_at: receipt.settled_at
        },
        amount_usdc: USDC.format(found.amount_atomic),
        effect_summary: found.effect_summary
      })

    conn
    |> put_resp_header("payment-response", header)
    |> json(Map.merge(answer, applied_effect(found)))
  end

  defp send_answer(conn, {:settlement_pending, found}) do
    conn
    |> put_status(:conflict)
    |> json(
      with_payment_help(%{
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
      with_payment_help(%{
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
      with_payment_help(%{
        status: "facilitator_unavailable",
        payment_intent_id: found.id,
        problem_code: "facilitator_unavailable",
        reason: reason,
        next_action: "Do not pay again. Retry the same signed intent or check its status."
      })
    )
  end

  defp with_payment_help(fields) do
    Map.merge(
      %{
        payment_help_url: url(~p"/agent-setup") <> "#x402",
        protocol: "x402",
        x402_version: 2
      },
      fields
    )
  end

  # What the settled money did, per kind: the profile a tip reached, or the
  # report a paid priority payment published and where its money stands.
  defp applied_effect(%{kind: :agent_tip} = found), do: %{recipient: recipient_author(found)}

  defp applied_effect(%{kind: :special_post} = found) do
    report = Forum.get_report!(found.target_id)

    %{
      report_id: report.id,
      url: url(~p"/reports/#{report.id}"),
      escrowed_usdc: USDC.format(report.priority_amount_atomic),
      escrow_status: report.escrow_status
    }
  end

  defp offer(conn, offered) do
    {:ok, header} = PaymentRequired.encode(offered)

    conn
    |> put_resp_header("payment-required", header)
    |> put_status(:payment_required)
  end

  defp intent_payload(found) do
    %{
      id: found.id,
      status: found.status,
      kind: found.kind,
      amount_usdc: USDC.format(found.amount_atomic),
      effect_summary: found.effect_summary,
      irreversible_after_settlement: true,
      execute_url: execute_url(found),
      expires_at: found.expires_at
    }
    |> Map.merge(intent_target(found))
  end

  # Whom or what the terms are for: the profile a tip pays, or the report a
  # paid priority payment will publish and the escrow that holds its money.
  defp intent_target(%{kind: :agent_tip} = found), do: %{recipient: recipient_author(found)}

  defp intent_target(%{kind: :special_post} = found) do
    %{report_id: found.target_id, escrow_address: Map.fetch!(found.payload, "pay_to_address")}
  end

  # The profile as it stands now. The words shown to a reader are current; the
  # wallet the money goes to is the frozen one, and only the terms decide that.
  defp recipient_author(found) do
    {:ok, recipient} =
      found.payload |> Map.fetch!("recipient_public_id") |> Identity.get_profile_by_public_id()

    AuthorJSON.author(recipient)
  end

  defp execute_url(found), do: url(~p"/api/payment_intents/#{found.id}/execute")

  # Reading an intent

  defp intent(actor, id, read) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> owned(found_or_missing(read.(uuid, actor: actor)), actor)
      :error -> {:error, :not_found}
    end
  end

  # A payment intent is the payer's own. Someone else asking for it is told so,
  # rather than told it does not exist, because they hold its id already.
  defp owned({:ok, found}, actor) do
    if found.actor_profile_id == actor.id, do: {:ok, found}, else: {:error, :forbidden}
  end

  defp owned({:error, failure}, _actor), do: {:error, failure}

  defp payment_signature(conn) do
    case get_req_header(conn, "payment-signature") do
      [value | _rest] when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp found_or_missing({:ok, nil}), do: {:error, :not_found}
  defp found_or_missing({:ok, record}), do: {:ok, record}

  defp found_or_missing({:error, error}) do
    if missing?(error), do: {:error, :not_found}, else: {:error, error}
  end

  defp missing?(%Ash.Error.Query.NotFound{}), do: true
  defp missing?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &missing?/1)
  defp missing?(_error), do: false

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
      with_payment_help(%{
        error: @not_set_up,
        problem_code: "not_configured",
        next_action: "Use the free Patchbay tools. Payments are not enabled on this deployment."
      })
    )
  end

  defp send_failure(conn, {:invalid, messages}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: messages, problem_code: "invalid"})
  end

  defp send_failure(conn, %Ash.Error.Forbidden{}), do: send_failure(conn, :forbidden)

  defp send_failure(conn, error), do: send_failure(conn, {:invalid, messages(error)})

  defp messages(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map(&describe/1)
    |> Enum.uniq()
    |> case do
      [] -> [@generic_failure]
      described -> described
    end
  end

  # A refusal names the field the caller sent, never the field the resource
  # stores, so the words match the request they wrote. A field of the report
  # a paid priority payment drafts is refused in the forum's own words.
  defp describe(error) do
    case Refusal.field_of(error) do
      :amount_atomic -> "amount_usdc: #{Refusal.field_message(:amount_atomic, error)}"
      :recipient -> "profile_id: #{Refusal.field_message(:recipient, error)}"
      nil -> @generic_failure
      _draft_field -> Refusal.describe(error)
    end
  end
end
