defmodule PatchbayWeb.PaymentsAPI.Purchase do
  @moduledoc """
  One way to buy a paid action, whichever door the buyer came through: the
  HTTP payment endpoints, the wallet-signed agent endpoints behind the
  command-line client, and the hosted MCP tools all run this and nothing else.

  Preparing an action freezes what it will cost and who receives the money.
  Executing it hands back the x402 terms to sign, and then, once a signed
  payment arrives, checks that payment against those same frozen terms before
  any money moves. Nothing the caller sends can change the amount or the
  destination after the fact: the terms are read from the stored intent every
  time, never from the request. The intent is settled at most once, and
  reading it back never pays.

  The money never passes through Patchbay. The payer's wallet pays the wallet
  the terms name, a profile's own for a tip, the escrow contract for a paid
  priority report and the assist wallet for a paid assist, a payment service
  verifies and settles it, and what is stored here is the record of what was
  promised and what happened. What the money bought is then carried out per
  kind: a tip is complete once settled, a paid priority report is published
  from its frozen terms, and a paid assist's run is opened from its.

  A short row lock commits the settlement attempt before external dispatch.
  A crash leaves an uncertain intent for reconciliation, never an automatic
  second payment. Settlement evidence commits before publication and escrow
  submission, so those later failures cannot erase the payment receipt.
  """

  use PatchbayWeb, :verified_routes

  require Ash.Query

  alias Patchbay.Assist
  alias Patchbay.Assist.Request, as: AssistRequest
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
  alias PatchbayWeb.AssistAPI.Runs
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.ForumAPI.Refusal
  alias X402.Extensions.PaymentIdentifier
  alias X402.Facilitator
  alias X402.PaymentSignature
  alias X402.Scheme.ExactEVM

  # The registered name of the payment service client, configured in
  # config/runtime.exs and started with the application.
  @facilitator Patchbay.Payments.Facilitator

  # How long the payment service may take to settle a signed payment. It is
  # advertised in the terms, so a wallet knows what window it is signing for.
  @max_timeout_seconds 300

  @generic_failure "That could not be done. Check the values you sent and try again."

  @amount_shape "amount_usdc: must be an amount of dollars written as text, " <>
                  "such as \"2.00\", with at most six decimal places"

  @profile_shape "profile_id: must be the public id of the profile being paid, such as \"agt_2f9c1d\""

  @unknown_profile "profile_id: there is no profile with that id"

  @typedoc """
  What an execute carries besides the intent's id: the signed payment, if the
  payer has signed (the x402 payment as a map, or the encoded
  `payment-signature` header); the wallet the payment must have been signed by,
  when the door knows nothing else about the caller; and the browser's forum
  identity, which is what a report paid for on a page is filed under.
  """
  @type request :: %{
          payment: map() | String.t() | nil,
          payer: String.t() | nil,
          browser_session_id: String.t() | nil
        }

  @typedoc "Where a payment intent stands after an execute, for the door to answer."
  @type answer ::
          {:payment_required, PaymentIntent.t()}
          | {:payment_rejected, PaymentIntent.t(), String.t()}
          | {:applied, PaymentIntent.t(), PaymentReceipt.t()}
          | {:settled, PaymentIntent.t(), PaymentReceipt.t()}
          | {:settlement_pending, PaymentIntent.t()}
          | {:expired, PaymentIntent.t()}
          | {:facilitator_unavailable, PaymentIntent.t(), String.t()}
          | {:error, term()}

  # Preparing a payment

  @doc "The amount an action names, in USDC's atomic units."
  @spec amount(map()) :: {:ok, pos_integer()} | {:error, {:invalid, [String.t()]}}
  def amount(%{"amount_usdc" => written}) when is_binary(written) do
    case USDC.parse(written) do
      {:ok, amount_atomic} -> {:ok, amount_atomic}
      :error -> {:error, {:invalid, [@amount_shape]}}
    end
  end

  def amount(_args), do: {:error, {:invalid, [@amount_shape]}}

  @doc "Freezes the terms of a tip from `actor` to the profile the args name."
  @spec prepare_agent_tip(struct(), map()) :: {:ok, PaymentIntent.t()} | {:error, term()}
  def prepare_agent_tip(actor, args) do
    with {:ok, amount_atomic} <- amount(args),
         {:ok, recipient} <- tip_recipient(args) do
      Payments.prepare_agent_tip(%{recipient: recipient, amount_atomic: amount_atomic},
        actor: actor
      )
    end
  end

  defp tip_recipient(%{"profile_id" => public_id}) when is_binary(public_id) do
    case found_or_missing(Identity.get_profile_by_public_id(public_id)) do
      {:ok, recipient} -> {:ok, recipient}
      {:error, :not_found} -> {:error, {:invalid, [@unknown_profile]}}
      {:error, failure} -> {:error, failure}
    end
  end

  defp tip_recipient(_args), do: {:error, {:invalid, [@profile_shape]}}

  @doc """
  Freezes the terms of a paid priority report drafted by `actor` from the
  report's fields and its `amount_usdc`.
  """
  @spec prepare_special_post(struct(), map()) :: {:ok, PaymentIntent.t()} | {:error, term()}
  def prepare_special_post(actor, args) do
    with {:ok, draft, amount_atomic} <- special_post_terms(args) do
      prepare(actor, draft, amount_atomic)
    end
  end

  @doc """
  The terms on offer to `actor` for this paid priority report: the intent it
  already prepared for the same report and amount, while those terms still
  stand, or fresh ones. A caller that asks again after a timeout, from any
  door, is answered with the purchase it started and never a second one.
  """
  @spec special_post_on_offer(struct(), map()) :: {:ok, PaymentIntent.t()} | {:error, term()}
  def special_post_on_offer(actor, args) do
    with {:ok, draft, amount_atomic} <- special_post_terms(args) do
      case on_offer(actor, draft, amount_atomic) do
        nil -> prepare(actor, draft, amount_atomic)
        found -> {:ok, found}
      end
    end
  end

  defp special_post_terms(args) do
    with :ok <- escrow_set_up(),
         {:ok, amount_atomic} <- amount(args),
         {:ok, draft} <- OtherSiteReport.draft(Map.delete(args, "amount_usdc")) do
      {:ok, draft, amount_atomic}
    end
  end

  defp escrow_set_up do
    if Escrow.contract_address(), do: :ok, else: {:error, :not_configured}
  end

  # The actor's own intents for this amount whose terms have not run out; the
  # one for the same draft, newest first, is the purchase already under way.
  defp on_offer(actor, draft, amount_atomic) do
    PaymentIntent
    |> Ash.Query.filter(
      kind == :special_post and amount_atomic == ^amount_atomic and
        expires_at > ^DateTime.utc_now()
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: actor)
    |> Enum.find(&(&1.payload["draft"] == draft))
  end

  # The site and the tool the draft names are registered alongside the terms,
  # so a draft that is refused leaves no empty board behind it. The draft
  # itself is checked by the terms' own action, against the forum's rules,
  # before anything is written.
  defp prepare(actor, draft, amount_atomic) do
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

  @doc """
  Freezes the terms of a paid assist for `actor` from the request's fields.
  The fee is fixed; the caller names no amount.
  """
  @spec prepare_jev_assist(struct(), map()) :: {:ok, PaymentIntent.t()} | {:error, term()}
  def prepare_jev_assist(actor, args) do
    with :ok <- assist_set_up(),
         {:ok, request} <- AssistRequest.draft(args) do
      Payments.prepare_jev_assist(%{request: request}, actor: actor)
    end
  end

  defp assist_set_up do
    if Assist.pay_to_address(), do: :ok, else: {:error, :assist_not_configured}
  end

  # Executing a payment intent

  @doc """
  Moves `actor`'s intent `id` one step on: offers the terms when no payment
  came, or checks the payment against them, settles it once, and carries out
  what it bought. Only the caller that commits the pending transition
  dispatches to the payment service, after the transaction has committed.
  """
  @spec execute(struct(), String.t(), request()) :: answer()
  def execute(actor, id, request) do
    case Ash.transact([PaymentIntent, PaymentReceipt], fn -> attempt(actor, id, request) end) do
      {:ok, {:settled, {:dispatch, found, payment, requirement, request}}} ->
        settle(actor, found, payment, requirement, request)

      {:ok, {:settled, answer}} ->
        answer

      {:error, failed_write} ->
        {:error, failed_write}
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

  defp advance(_actor, %{status: :applied} = found, _request),
    do: {:applied, found, found.receipt}

  defp advance(_actor, %{status: :settled, kind: :agent_tip} = found, _request),
    do: {:applied, found, found.receipt}

  # A settled assist whose run could not be opened is tried again on the
  # next call: the run is opened from the same frozen terms, and one payment
  # can never open two.
  defp advance(actor, %{status: :settled, kind: :jev_assist} = found, request) do
    with {:ok, :complete} <- carry_out(found, found.receipt, actor, request),
         {:ok, applied} <- Payments.mark_applied(found, actor: actor) do
      {:applied, applied, found.receipt}
    else
      _incomplete -> {:settled, found, found.receipt}
    end
  end

  defp advance(_actor, %{status: :settled} = found, _request),
    do: {:settled, found, found.receipt}

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

  defp offer_or_settle(actor, found, %{payment: nil}) do
    case Payments.mark_payment_required(found, actor: actor) do
      {:ok, waiting} -> {:payment_required, waiting}
      {:error, failure} -> {:error, failure}
    end
  end

  defp offer_or_settle(actor, found, request) do
    requirement = requirement(found)

    case checked_payment(request, found, requirement) do
      {:ok, payment} ->
        with {:ok, pending} <- Payments.mark_settlement_pending(found, actor: actor) do
          {:dispatch, pending, payment, requirement, request}
        end

      {:refused, reason} ->
        {:payment_rejected, found, reason}

      {:unavailable, reason} ->
        {:facilitator_unavailable, found, reason}
    end
  end

  # Checking a payment against the frozen terms

  defp checked_payment(request, found, requirement) do
    with {:ok, payment} <- decoded(request.payment, requirement),
         :ok <- signed_by(payment, request.payer),
         :ok <- names_this_intent(payment, found),
         :ok <- prechecked(payment, requirement),
         :ok <- verified(payment, requirement) do
      {:ok, payment}
    end
  end

  # Decoding matches the signed `accepted` terms against this intent's own
  # requirement field for field, so a signature made for any other amount,
  # asset, network or wallet is refused before anything else happens.
  defp decoded(payment, requirement) when is_binary(payment) do
    payment |> PaymentSignature.decode_and_validate(requirement) |> decoded()
  end

  defp decoded(payment, requirement) when is_map(payment) do
    payment |> PaymentSignature.validate(requirement) |> decoded()
  end

  defp decoded({:ok, payment}), do: {:ok, payment}

  defp decoded({:error, :no_matching_requirements}),
    do: {:refused, "That payment was signed for different terms than this payment intent's."}

  defp decoded({:error, _reason}),
    do: {:refused, "That payment signature could not be read as an x402 version 2 payment."}

  # A door that knows the buyer only by the wallet it named is held to a
  # payment from that wallet, so nobody buys in another wallet's name.
  defp signed_by(_payment, nil), do: :ok

  defp signed_by(payment, payer) do
    from = get_in(payment, ["payload", "authorization", "from"])

    if is_binary(from) and String.downcase(from) == payer,
      do: :ok,
      else: {:refused, "That payment was signed by a different wallet than wallet_address names."}
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
        {:unavailable, "The payment service could not be reached before a settlement result."}
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
    persisted =
      Ash.transact([PaymentIntent, PaymentReceipt], fn ->
        with {:ok, receipt} <- record_receipt(actor, found, payment, body),
             {:ok, settled} <- Payments.mark_settled(found, actor: actor) do
          {settled, receipt}
        end
      end)

    case persisted do
      {:ok, {settled, receipt}} ->
        with {:ok, :complete} <- carry_out(settled, receipt, actor, request),
             {:ok, applied} <- Payments.mark_applied(settled, actor: actor) do
          {:applied, applied, receipt}
        else
          _incomplete -> {:settled, settled, receipt}
        end

      {:error, _failed_write} ->
        # The already-committed pending marker survives. Never redispatch.
        {:settlement_pending, found}
    end
  end

  # What the money bought, and whether it is complete. A tip is complete the
  # moment it settles: the money is already in the recipient's wallet. A paid
  # priority report is published from its frozen terms and is complete once
  # Base has been handed the settled money to record against it. A paid
  # assist is complete once its run is open for Patchbay to work on.
  defp carry_out(%{kind: :agent_tip}, _receipt, _actor, _request), do: {:ok, :complete}

  defp carry_out(%{kind: :special_post} = settled, receipt, actor, request) do
    with {:ok, report} <-
           SpecialPost.publish(settled, receipt,
             actor: actor,
             browser_session_id: request.browser_session_id
           ) do
      {:ok, if(report.escrow_status == :credit_submitted, do: :complete, else: :incomplete)}
    end
  end

  defp carry_out(%{kind: :jev_assist} = settled, _receipt, actor, request) do
    with {:ok, _run} <-
           Assist.open_run(%{intent: settled, browser_session_id: request.browser_session_id},
             actor: actor
           ) do
      {:ok, :complete}
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

  # Reading an intent

  @doc "The intent `id` as it stands, with its receipt, if it is `actor`'s."
  @spec read(struct(), String.t()) :: {:ok, PaymentIntent.t()} | {:error, term()}
  def read(actor, id) do
    intent(actor, id, fn id, opts ->
      Payments.get_payment_intent(id, Keyword.put(opts, :load, [:receipt]))
    end)
  end

  defp intent(actor, id, read) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> owned(found_or_missing(read.(uuid, actor: actor)), actor)
      :error -> {:error, :not_found}
    end
  end

  # Ash filters out other payers' intents. Keep this ownership check as defense
  # in depth; denied reads reveal neither the record nor its existence.
  defp owned({:ok, found}, actor) do
    permitted_kind =
      actor.authentication_origin != :wallet or found.kind in [:special_post, :jev_assist]

    if found.actor_profile_id == actor.id and permitted_kind,
      do: {:ok, found},
      else: {:error, :not_found}
  end

  defp owned({:error, failure}, _actor), do: {:error, failure}

  defp found_or_missing({:ok, nil}), do: {:error, :not_found}
  defp found_or_missing({:ok, record}), do: {:ok, record}

  defp found_or_missing({:error, error}) do
    if missing?(error), do: {:error, :not_found}, else: {:error, error}
  end

  @doc "Whether an error means there is no such intent."
  @spec missing?(term()) :: boolean()
  def missing?(%Ash.Error.Query.NotFound{}), do: true
  def missing?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &missing?/1)
  def missing?(_error), do: false

  @doc """
  A refusal in the caller's words: it names the field the caller sent, never
  the field the resource stores. A field of the report a paid priority payment
  drafts is refused in the forum's own words.
  """
  @spec refusal_messages(term()) :: [String.t()]
  def refusal_messages(error) do
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

  defp describe(error) do
    case Refusal.field_of(error) do
      :amount_atomic -> "amount_usdc: #{Refusal.field_message(:amount_atomic, error)}"
      :recipient -> "profile_id: #{Refusal.field_message(:recipient, error)}"
      nil -> @generic_failure
      _draft_field -> Refusal.describe(error)
    end
  end

  # The terms

  @doc "The x402 terms for an intent, with `error` as the sentence asking for payment."
  @spec terms(PaymentIntent.t(), String.t()) :: map()
  def terms(found, error) do
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

  # What a door tells the buyer

  @doc "The fields every payment answer carries: the protocol and where to read about it."
  @spec payment_help(map()) :: map()
  def payment_help(fields) do
    Map.merge(
      %{
        payment_help_url: url(~p"/agent-setup") <> "#x402",
        protocol: "x402",
        x402_version: 2
      },
      fields
    )
  end

  @doc "The intent as prepared: what it costs, what it does, where to pay."
  @spec intent_payload(PaymentIntent.t()) :: map()
  def intent_payload(found) do
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

  @doc "What was paid and when, as the receipt records it."
  @spec receipt_payload(PaymentReceipt.t()) :: map()
  def receipt_payload(receipt) do
    %{
      transaction_hash: receipt.transaction_hash,
      payer_address: receipt.payer_address,
      settled_at: receipt.settled_at
    }
  end

  @doc """
  What a settled or uncertain intent's buyer needs to know when reading it
  back: the receipt, the effect, and whether anything is left for a person.
  """
  @spec recovery_payload(PaymentIntent.t()) :: map()
  def recovery_payload(%{status: :applied} = found) do
    result = applied_effect(found)

    %{
      receipt: receipt_payload(found.receipt),
      result: result,
      recovery_required: Map.get(result, :result_available) == false
    }
  end

  def recovery_payload(%{status: :settled} = found) do
    %{
      receipt: receipt_payload(found.receipt),
      result: applied_effect(found),
      recovery_required: found.kind != :agent_tip,
      next_action: settled_next_action(found.kind)
    }
  end

  def recovery_payload(%{status: :settlement_pending}) do
    %{
      recovery_required: true,
      next_action: "Do not pay again. Settlement is uncertain and requires reconciliation."
    }
  end

  def recovery_payload(_found), do: %{}

  defp settled_next_action(:agent_tip),
    do: "Payment settled. The tip is complete; do not pay again."

  defp settled_next_action(:special_post),
    do: "Payment settled. Do not pay again. Check the report and reconcile any incomplete effect."

  defp settled_next_action(:jev_assist),
    do: "Payment settled. Do not pay again. Patchbay will open the assist; keep reading this."

  @doc """
  What the settled money did, per kind: the profile a tip reached, the
  report a paid priority payment published and where its money stands, or
  the assist a payment opened and where it stands. Payment received and
  bounty confirmed are two facts: the second is what the chain has said,
  read back by the escrow watch, never assumed.
  """
  @spec applied_effect(PaymentIntent.t()) :: map()
  def applied_effect(%{kind: :agent_tip} = found), do: %{recipient: recipient_author(found)}

  def applied_effect(%{kind: :special_post} = found) do
    case Forum.get_report(found.target_id) do
      {:ok, %{} = report} ->
        confirmation = SpecialPost.confirmation(report)

        %{
          report_id: report.id,
          url: url(~p"/reports/#{report.id}"),
          escrowed_usdc: USDC.format(report.priority_amount_atomic),
          escrow_status: report.escrow_status,
          escrow_funded_at: report.escrow_funded_at,
          credit_confirmation: to_string(confirmation),
          status_url: show_url(found),
          next_action: confirmation_next_action(confirmation),
          result_available: true
        }

      _unavailable ->
        %{
          report_id: found.target_id,
          result_available: false,
          credit_confirmation: "needs_attention",
          status_url: show_url(found),
          next_action: confirmation_next_action(:needs_attention)
        }
    end
  end

  # The intent was read under its payer's own policy and the run is that
  # intent's target, so the run is read here without an actor deliberately:
  # nothing but the payer's own run can be named by it.
  def applied_effect(%{kind: :jev_assist} = found) do
    case Assist.get_run(found.target_id, authorize?: false) do
      {:ok, %{} = run} ->
        %{
          run_id: run.id,
          run_status: run.status,
          outcome: run.outcome,
          assist_url: assist_url(found),
          next_action: Runs.next_action(run),
          result_available: true
        }

      _unavailable ->
        %{
          run_id: found.target_id,
          result_available: false,
          assist_url: assist_url(found),
          next_action:
            "Payment received. The assist has not been opened yet; keep reading assist_url. Do not pay again."
        }
    end
  end

  defp confirmation_next_action(:pending),
    do:
      "Payment received. The bounty is being confirmed on Base; read status_url again after a short wait. Do not pay again."

  defp confirmation_next_action(:confirmed),
    do: "Payment received and the bounty is confirmed on Base. Do not pay again."

  defp confirmation_next_action(:needs_attention),
    do:
      "Payment received. The bounty's record on Base needs a person at Patchbay; keep reading status_url. Do not pay again."

  # Whom or what the terms are for: the profile a tip pays, or the report a
  # paid priority payment will publish and the escrow that holds its money.
  defp intent_target(%{kind: :agent_tip} = found), do: %{recipient: recipient_author(found)}

  defp intent_target(%{kind: :special_post} = found) do
    %{report_id: found.target_id, escrow_address: Map.fetch!(found.payload, "pay_to_address")}
  end

  defp intent_target(%{kind: :jev_assist} = found) do
    %{
      run_id: found.target_id,
      site_url: get_in(found.payload, ["request", "site_url"]),
      assist_url: assist_url(found)
    }
  end

  # The profile as it stands now. The words shown to a reader are current; the
  # wallet the money goes to is the frozen one, and only the terms decide that.
  defp recipient_author(found) do
    public_id = Map.fetch!(found.payload, "recipient_public_id")

    case Identity.get_profile_by_public_id(public_id) do
      {:ok, %{} = recipient} ->
        AuthorJSON.author(recipient)

      _unavailable ->
        %{
          profile_id: public_id,
          agent_name: found.payload["recipient_agent_name"],
          human_name: nil,
          profile_url: nil,
          can_receive_usdc: false,
          profile_available: false
        }
    end
  end

  @doc "Where this intent is paid: the wallet-signed address for a wallet author, the page's otherwise."
  @spec execute_url(PaymentIntent.t()) :: String.t()
  def execute_url(%{payload: %{"author_origin" => "wallet"}} = found),
    do: url(~p"/api/agent/payment_intents/#{found.id}/execute")

  def execute_url(found), do: url(~p"/api/payment_intents/#{found.id}/execute")

  @doc "Where this intent is read back, likewise."
  @spec show_url(PaymentIntent.t()) :: String.t()
  def show_url(%{payload: %{"author_origin" => "wallet"}} = found),
    do: url(~p"/api/agent/payment_intents/#{found.id}")

  def show_url(found), do: url(~p"/api/payment_intents/#{found.id}")

  @doc "Where the assist an intent bought is read back, once it is open, likewise."
  @spec assist_url(PaymentIntent.t()) :: String.t()
  def assist_url(%{payload: %{"author_origin" => "wallet"}} = found),
    do: url(~p"/api/agent/assists/#{found.target_id}")

  def assist_url(found), do: url(~p"/api/assists/#{found.target_id}")
end
