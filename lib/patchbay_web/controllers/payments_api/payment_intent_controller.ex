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

  The money never passes through Patchbay. The payer's wallet pays the
  recipient's wallet, a payment service verifies and settles it, and what is
  stored here is the record of what was promised and what happened.

  One intent applies exactly once. The row is locked for the whole of an
  execute call, so two calls racing each other cannot both settle it, and a
  call that arrives after the effect was applied is answered with the stored
  result rather than charged again.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Payments
  alias Patchbay.Payments.PaymentIntent
  alias Patchbay.Payments.PaymentReceipt
  alias Patchbay.Payments.USDC
  alias PatchbayWeb.AuthorJSON
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

  @unknown_action "kind: must be agent_tip, and args must carry profile_id and amount_usdc"

  def create(conn, %{"kind" => "agent_tip", "args" => %{} = args}) do
    actor = conn.assigns.current_profile

    with {:ok, amount_atomic} <- tip_amount(args),
         {:ok, recipient} <- tip_recipient(args),
         {:ok, intent} <- Payments.prepare_agent_tip(tip(recipient, amount_atomic), actor: actor) do
      conn
      |> put_status(:created)
      |> json(intent_payload(intent))
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def create(conn, _params), do: send_failure(conn, {:invalid, [@unknown_action]})

  def execute(conn, %{"id" => id}) do
    actor = conn.assigns.current_profile

    case under_lock(actor, id, payment_signature(conn)) do
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

  # Preparing a tip

  defp tip(recipient, amount_atomic), do: %{recipient: recipient, amount_atomic: amount_atomic}

  defp tip_amount(%{"amount_usdc" => written}) when is_binary(written) do
    case USDC.parse(written) do
      {:ok, amount_atomic} -> {:ok, amount_atomic}
      :error -> {:error, {:invalid, [@amount_shape]}}
    end
  end

  defp tip_amount(_args), do: {:error, {:invalid, [@amount_shape]}}

  defp tip_recipient(%{"profile_id" => public_id}) when is_binary(public_id) do
    case found_or_missing(Identity.get_profile_by_public_id(public_id)) do
      {:ok, recipient} -> {:ok, recipient}
      {:error, :not_found} -> {:error, {:invalid, [@unknown_profile]}}
      {:error, failure} -> {:error, failure}
    end
  end

  defp tip_recipient(_args), do: {:error, {:invalid, [@profile_shape]}}

  # Executing a payment intent

  # The whole of an execute call happens under one row lock, so a settled
  # intent is applied exactly once however many calls arrive at once.
  defp under_lock(actor, id, signature) do
    case Ash.transact([PaymentIntent, PaymentReceipt], fn -> attempt(actor, id, signature) end) do
      {:ok, {:settled, answer}} -> answer
      {:error, failed_write} -> {:error, failed_write}
    end
  end

  # A refusal is an answer, and the status it wrote down travels out with it.
  # Only a write that genuinely failed undoes the transaction.
  defp attempt(actor, id, signature) do
    case locked(actor, id, signature) do
      {:error, failure} when is_exception(failure) -> {:error, failure}
      answer -> {:settled, answer}
    end
  end

  defp locked(actor, id, signature) do
    case intent(actor, id, &Payments.lock_payment_intent/2) do
      {:ok, found} -> advance(actor, found, signature)
      {:error, failure} -> {:error, failure}
    end
  end

  defp advance(_actor, %{status: status} = found, _signature)
       when status in [:settled, :applied] do
    {:applied, found, found.receipt}
  end

  defp advance(_actor, %{status: :settlement_pending} = found, _signature) do
    {:settlement_pending, found}
  end

  defp advance(actor, found, signature) do
    if DateTime.before?(found.expires_at, DateTime.utc_now()) do
      expire(actor, found)
    else
      offer_or_settle(actor, found, signature)
    end
  end

  defp expire(actor, found) do
    case Payments.expire_payment_intent(found, actor: actor) do
      {:ok, expired} -> {:expired, expired}
      {:error, failure} -> {:error, failure}
    end
  end

  defp offer_or_settle(actor, found, nil) do
    case Payments.mark_payment_required(found, actor: actor) do
      {:ok, waiting} -> {:payment_required, waiting}
      {:error, failure} -> {:error, failure}
    end
  end

  defp offer_or_settle(actor, found, signature) do
    requirement = requirement(found)

    case checked_payment(signature, found, requirement) do
      {:ok, payment} -> settle(actor, found, payment, requirement)
      {:refused, reason} -> {:payment_rejected, found, reason}
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
        {:refused, "That payment could not be checked just now. Try again in a moment."}
    end
  end

  defp invalid_message(%{"invalidReason" => reason}) when is_binary(reason) do
    "The payment service would not accept that payment: #{reason}."
  end

  defp invalid_message(_body), do: "The payment service would not accept that payment."

  # Settling

  defp settle(actor, found, payment, requirement) do
    case Facilitator.settle(@facilitator, payment, requirement) do
      {:ok, %{status: status, body: %{"success" => true} = body}} when status in 200..299 ->
        apply_payment(actor, found, payment, body)

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

  defp apply_payment(actor, found, payment, body) do
    with {:ok, receipt} <- record_receipt(actor, found, payment, body),
         {:ok, settled} <- Payments.mark_settled(found, actor: actor),
         {:ok, applied} <- Payments.mark_applied(settled, actor: actor) do
      {:applied, applied, receipt}
    end
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
      "payTo" => Map.fetch!(found.payload, "recipient_wallet_address"),
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
    |> json(%{
      status: "payment_required",
      payment_intent_id: found.id,
      payment_terms: offered,
      next_action: @pay_and_retry
    })
  end

  defp send_answer(conn, {:payment_rejected, found, reason}) do
    offered = terms(found, reason)

    conn
    |> offer(offered)
    |> json(%{
      status: "payment_required",
      payment_intent_id: found.id,
      payment_terms: offered,
      reason: reason,
      next_action: @pay_and_retry
    })
  end

  defp send_answer(conn, {:applied, found, receipt}) do
    {:ok, header} = PaymentResponse.encode(receipt.payment_response)

    conn
    |> put_resp_header("payment-response", header)
    |> json(%{
      status: "applied",
      payment_intent_id: found.id,
      receipt: %{
        transaction_hash: receipt.transaction_hash,
        payer_address: receipt.payer_address,
        settled_at: receipt.settled_at
      },
      recipient: recipient_author(found),
      amount_usdc: USDC.format(found.amount_atomic),
      effect_summary: found.effect_summary
    })
  end

  defp send_answer(conn, {:settlement_pending, found}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      status: "settlement_pending",
      payment_intent_id: found.id,
      next_action:
        "Do not pay again. This payment is being confirmed with the payment service by hand."
    })
  end

  defp send_answer(conn, {:expired, found}) do
    conn
    |> put_status(:gone)
    |> json(%{
      status: "expired",
      payment_intent_id: found.id,
      next_action: "These terms are no longer on offer. Prepare a new payment intent."
    })
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
      recipient: recipient_author(found),
      effect_summary: found.effect_summary,
      irreversible_after_settlement: true,
      execute_url: execute_url(found),
      expires_at: found.expires_at
    }
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
  # stores, so the words match the request they wrote.
  defp describe(error) do
    case field_of(error) do
      :amount_atomic -> amount_range_message()
      :recipient -> "profile_id: #{message_of(error)}"
      nil -> @generic_failure
      field -> "#{field}: #{message_of(error)}"
    end
  end

  defp amount_range_message do
    "amount_usdc: must be between #{USDC.format(PaymentIntent.min_amount_atomic())} and " <>
      "#{USDC.format(PaymentIntent.max_amount_atomic())} USDC"
  end

  defp field_of(error) do
    case {Map.get(error, :field), Map.get(error, :fields)} do
      {field, _fields} when is_atom(field) and not is_nil(field) -> field
      {_field, [field | _rest]} when is_atom(field) -> field
      _absent -> nil
    end
  end

  defp message_of(error) do
    case Map.get(error, :message) do
      message when is_binary(message) -> substitute(message, Map.get(error, :vars) || [])
      _absent -> @generic_failure
    end
  end

  defp substitute(message, vars) do
    Enum.reduce(vars, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
