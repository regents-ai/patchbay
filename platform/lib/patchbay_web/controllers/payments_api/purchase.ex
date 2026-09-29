defmodule PatchbayWeb.PaymentsAPI.Purchase do
  @moduledoc """
  One way to buy a paid action, whichever door the buyer came through: the
  HTTP payment endpoints, the wallet-signed agent endpoints behind the
  command-line client, and the hosted MCP tools all run this and nothing else.

  The payment itself is the Regents payments library's
  (`RegentPayments.Purchase`): it freezes the terms, checks a signed payment
  against them, settles it once and has Patchbay's offer carry out what it
  bought. What is here is Patchbay's side of it: reading what the caller asked
  for into an offer's input, refusing a purchase that cannot go ahead before
  anyone is asked to pay, following up once the payment has committed, and
  the words and addresses every door answers with.

  The money never passes through Patchbay. The payer's wallet pays the wallet
  the terms name, a profile's own for a tip, the escrow contract for a paid
  priority report and the assist wallet for a paid assist.
  """

  use PatchbayWeb, :verified_routes

  alias Patchbay.Assist
  alias Patchbay.Assist.Request, as: AssistRequest
  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool
  alias Patchbay.Identity
  alias Patchbay.Payments
  alias Patchbay.Payments.AgentTip
  alias Patchbay.Payments.JevAssist
  alias Patchbay.Payments.SpecialPost
  alias PatchbayWeb.AssistAPI.Runs
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.ForumAPI.Refusal
  alias RegentPayments.PaymentIntent
  alias RegentPayments.USDC
  alias RegentPayments.WalletPayment

  @generic_failure "That could not be done. Check the values you sent and try again."

  @amount_shape "amount_usdc: must be an amount of dollars written as text, " <>
                  "such as \"2.00\", with at most six decimal places"

  @profile_shape "profile_id: must be the public id of the profile being paid, such as \"agt_2f9c1d\""

  @unknown_profile "profile_id: there is no profile with that id"

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
      RegentPayments.Purchase.prepare(
        AgentTip,
        %{recipient: recipient, amount_atomic: amount_atomic},
        actor
      )
    end
  end

  defp tip_recipient(%{"profile_id" => public_id}) when is_binary(public_id) do
    case Identity.get_profile_by_public_id(public_id) do
      {:ok, %{} = recipient} ->
        {:ok, recipient}

      {:ok, nil} ->
        {:error, {:invalid, [@unknown_profile]}}

      {:error, failure} ->
        if RegentPayments.Purchase.missing?(failure),
          do: {:error, {:invalid, [@unknown_profile]}},
          else: {:error, failure}
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
      same? = &(&1.amount_atomic == amount_atomic and &1.payload["draft"] == draft)

      case RegentPayments.Purchase.on_offer(SpecialPost, actor, same?) do
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

  # The site and the tool the draft names are registered alongside the terms,
  # so a draft that is refused leaves no empty board behind it. The draft
  # itself is checked by the offer, against the forum's rules, before
  # anything is written.
  defp prepare(actor, draft, amount_atomic) do
    case Ash.transact([Site, Tool, PaymentIntent], fn -> frozen(actor, draft, amount_atomic) end) do
      {:ok, {:ok, intent}} -> {:ok, intent}
      {:error, failure} -> {:error, failure}
    end
  end

  defp frozen(actor, draft, amount_atomic) do
    with {:ok, tool} <- OtherSiteReport.resolve_tool(draft) do
      RegentPayments.Purchase.prepare(
        SpecialPost,
        %{tool: tool, draft: draft, amount_atomic: amount_atomic},
        actor
      )
    end
  end

  @doc """
  Freezes the terms of a paid assist for `actor` from the request's fields,
  asked from the browser `browser_session_id` names, if any. The fee is
  fixed; the caller names no amount.
  """
  @spec prepare_jev_assist(struct(), map(), Ash.UUID.t() | nil) ::
          {:ok, PaymentIntent.t()} | {:error, term()}
  def prepare_jev_assist(actor, args, browser_session_id) do
    with :ok <- assist_set_up(),
         :ok <- no_assist_running(actor),
         :ok <- no_fix_running(actor, browser_session_id),
         {:ok, request} <- AssistRequest.draft(args) do
      RegentPayments.Purchase.prepare(JevAssist, %{request: request}, actor)
    end
  end

  @doc """
  The terms on offer to `actor` for this assist: the intent it already
  prepared for the same request, while those terms still stand, or fresh
  ones. A caller that asks again after a timeout is answered with the
  purchase it started and never a second one.
  """
  @spec assist_on_offer(struct(), map()) :: {:ok, PaymentIntent.t()} | {:error, term()}
  def assist_on_offer(actor, args) do
    with :ok <- assist_set_up(),
         {:ok, request} <- AssistRequest.draft(args) do
      case RegentPayments.Purchase.on_offer(JevAssist, actor, &(&1.payload["request"] == request)) do
        nil -> prepare_assist(actor, request)
        found -> {:ok, found}
      end
    end
  end

  defp prepare_assist(actor, request) do
    with :ok <- no_assist_running(actor) do
      RegentPayments.Purchase.prepare(JevAssist, %{request: request}, actor)
    end
  end

  defp assist_set_up do
    if Assist.pay_to_address(), do: :ok, else: {:error, :assist_not_configured}
  end

  # One assist at a time for each payer: a second is refused, with the one
  # under way, before anyone is asked to pay. The database repeats the check
  # when a run is opened, so a payment that slipped past this one opens its
  # run on a later call instead.
  defp no_assist_running(actor) do
    case Assist.get_open_run_for_payer(actor.id, actor: actor) do
      {:ok, nil} -> :ok
      {:ok, run} -> {:error, {:assist_running, run, run_url(actor, run)}}
      {:error, error} -> {:error, error}
    end
  end

  # The same for the browser: a fix it asked for before signing in has no
  # payer, and the run a payment from it opens is one open run too.
  defp no_fix_running(_actor, nil), do: :ok

  defp no_fix_running(actor, browser_session_id) do
    # Patchbay's own look-up for the browser, by the identity in its signed
    # cookie; only the run's id and address go back, to that same browser.
    case Assist.get_open_run_for_browser(browser_session_id, authorize?: false) do
      {:ok, nil} -> :ok
      {:ok, run} -> {:error, {:assist_running, run, run_url(actor, run)}}
      {:error, error} -> {:error, error}
    end
  end

  # Paying

  @doc """
  Moves `actor`'s intent `id` one step on through the payments library, then
  follows up on what it bought (`Patchbay.Payments.follow_up/1`). `request`
  carries the signed payment, if any, the wallet it must come from, and the
  browser the purchase was made from as `context.browser_session_id`.
  """
  @spec execute(struct(), String.t(), RegentPayments.Purchase.request()) ::
          RegentPayments.Purchase.answer()
  def execute(actor, id, request) do
    actor
    |> RegentPayments.Purchase.execute(id, request)
    |> Payments.follow_up()
  end

  @doc """
  A page's payment for `actor`'s intent `id` with the wallet its person
  signed in with (`RegentPayments.WalletPayment.pay/4`), made from the
  browser `browser_session_id` names, then followed up like `execute/3`.
  """
  @spec pay(struct(), String.t(), map(), Ash.UUID.t() | nil) ::
          RegentPayments.WalletPayment.answer()
  def pay(actor, id, params, browser_session_id) do
    actor
    |> WalletPayment.pay(id, params, %{browser_session_id: browser_session_id})
    |> Payments.follow_up()
  end

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

  @doc "The x402 terms for an intent, with `error` as the sentence asking for payment."
  @spec terms(PaymentIntent.t(), String.t()) :: map()
  def terms(found, error), do: RegentPayments.Purchase.terms(found, error, execute_url(found))

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

  @doc """
  What a settled or uncertain intent's buyer needs to know when reading it
  back: the receipt, the effect, and whether anything is left for a person.
  """
  @spec recovery_payload(PaymentIntent.t()) :: map()
  def recovery_payload(%{status: :applied} = found) do
    result = applied_effect(found)

    %{
      receipt: RegentPayments.Purchase.receipt_payload(found.receipt),
      result: result,
      recovery_required: Map.get(result, :result_available) == false
    }
  end

  def recovery_payload(%{status: :settled} = found) do
    %{
      receipt: RegentPayments.Purchase.receipt_payload(found.receipt),
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
    do:
      "Payment settled. Do not pay again. The assist opens on your next call here, " <>
        "once Patchbay has answered your earlier one."

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

  @doc "Where `actor` reads the run `run` back, through the door the actor came in by."
  @spec run_url(struct(), Assist.Run.t()) :: String.t()
  def run_url(%{authentication_origin: :wallet}, run), do: url(~p"/api/agent/assists/#{run.id}")
  def run_url(_actor, run), do: url(~p"/api/assists/#{run.id}")
end
