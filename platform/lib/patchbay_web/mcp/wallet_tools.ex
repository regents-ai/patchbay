defmodule PatchbayWeb.MCP.WalletTools do
  @moduledoc """
  The hosted tools that act for a wallet: paying for a priority report,
  reading the payment back, accepting the answer to that report and asking
  its bounty back.

  The hosted door carries no signed-in wallet, so every one of these names the
  wallet it acts for in `wallet_address`, and the wallet is proven per call,
  never taken on the caller's word. A payment proves itself: the signed x402
  payment has to come from the wallet named, and it arrives in the request's
  `_meta["x402/payment"]` as the x402 MCP transport says, after a first call
  answered with the terms. Accepting an answer and asking the bounty back
  move money without a payment, so the wallet signs for the exact action
  instead (`PatchbayWeb.MCP.WalletProof`).

  The purchase itself is `PatchbayWeb.PaymentsAPI.Purchase`, the one process
  every door runs, so asking for the same report at the same price again
  within its window is answered with the purchase already under way and never
  starts a second one. Nothing here holds a key or moves money on its own.
  """

  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Forum.SolutionAccept
  alias Patchbay.Identity
  alias Patchbay.Payments.USDC
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.ForumAPI.Refusal
  alias PatchbayWeb.MCP.WalletProof
  alias PatchbayWeb.MD
  alias PatchbayWeb.PaymentsAPI.Purchase

  @names ~w(post_priority_report get_payment_status accept_solution withdraw_priority_report)

  @wallet_shape "wallet_address: must be a Base wallet address, 0x followed by 40 hex characters"

  @challenge_error "Payment is required to publish this priority report."

  @not_set_up "Paid priority posts are not set up on this Patchbay."

  @suspended %{
    problem_code: "suspended",
    error:
      "That wallet's profile is suspended on Patchbay. It cannot pay, read payments or act on reports here."
  }

  @wallet_address %{
    "type" => "string",
    "pattern" => "^0x[0-9a-fA-F]{40}$",
    "description" =>
      "The wallet this call acts for, as its Base address. This connection has no signed-in wallet; the wallet is proven by the payment it signs, or by signing the challenge this tool answers with."
  }

  @proof %{
    "challenge" => %{
      "type" => "string",
      "description" =>
        "The challenge this tool answered with when called without one. Send it back together with signature."
    },
    "signature" => %{
      "type" => "string",
      "description" =>
        "The wallet's signature over the typed_data this tool answered with, from eth_signTypedData_v4 or any EIP-712 signer."
    }
  }

  @doc "The tool names this module runs."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  The tool's input schema as the hosted door lists it: the manifest's schema
  plus the arguments only this door needs, the wallet named on every call and
  the challenge and signature the wallet actions take on their second call.
  """
  @spec hosted_schema(String.t(), map()) :: map()
  def hosted_schema(name, schema) when name in @names do
    proof = if name in ~w(accept_solution withdraw_priority_report), do: @proof, else: %{}

    schema
    |> Map.update!(
      "properties",
      &(&1 |> Map.put("wallet_address", @wallet_address) |> Map.merge(proof))
    )
    |> Map.update("required", ["wallet_address"], &(&1 ++ ["wallet_address"]))
  end

  def hosted_schema(_name, schema), do: schema

  @typedoc """
  What a wallet tool answers: a plain answer or problem, the x402 terms to pay
  with the handoff for a client that cannot, or a paid answer with the
  settlement receipt to carry in the result's `_meta`.
  """
  @type answer ::
          {:ok, map()}
          | {:error, map()}
          | {:payment_required, map(), map()}
          | {:paid, map(), map()}

  @doc "Runs one wallet tool; `meta` is the request's `_meta`, where a payment rides."
  @spec run(String.t(), map(), map()) :: answer()
  def run("post_priority_report", %{"wallet_address" => wallet} = arguments, meta) do
    with {:ok, wallet} <- wallet_address(wallet),
         {:ok, named} <- Identity.upsert_from_wallet(%{wallet_address: wallet}),
         {:ok, actor} <- active(named),
         {:ok, found} <-
           Purchase.special_post_on_offer(actor, Map.delete(arguments, "wallet_address")) do
      request = %{payment: payment(meta), payer: wallet, browser_session_id: nil}
      purchase_answer(Purchase.execute(actor, found.id, request))
    else
      {:error, failure} -> purchase_refusal(failure)
    end
  end

  def run("get_payment_status", %{"payment_intent_id" => id, "wallet_address" => wallet}, _meta) do
    with {:ok, wallet} <- wallet_address(wallet),
         {:ok, actor} <- wallet_profile(wallet),
         {:ok, found} <- Purchase.read(actor, id) do
      {:ok, status_answer(found)}
    else
      {:error, failure} -> purchase_refusal(failure)
    end
  end

  def run(
        "accept_solution",
        %{"report_id" => report_id, "reply_id" => reply_id} = arguments,
        _meta
      ) do
    arguments
    |> proven("accept_solution", report_id, reply_id, fn actor ->
      SolutionAccept.run(report_id, reply_id, actor)
    end)
    |> case do
      {:ok, released} ->
        {:ok,
         %{
           accepted: true,
           report_id: released.id,
           reply_id: released.accepted_reply_id,
           escrow_status: released.escrow_status,
           release_tx_hash: released.escrow_release_tx_hash,
           winner: AuthorJSON.author(released.accepted_reply.author),
           url: report_page(released.id)
         }}

      {:error, failure} ->
        report_refusal(failure, SolutionAccept, "accept an answer to it")
    end
  end

  def run("withdraw_priority_report", %{"report_id" => report_id} = arguments, _meta) do
    arguments
    |> proven("withdraw_priority_report", report_id, "", fn actor ->
      PriorityRefund.run(report_id, actor)
    end)
    |> case do
      {:ok, refunded} ->
        {:ok,
         %{
           # Base decides, and it decides later than this answer, so this says
           # only whether the request reached the chain.
           asked: is_binary(refunded.escrow_refund_tx_hash),
           report_id: refunded.id,
           escrow_status: refunded.escrow_status,
           refund_tx_hash: refunded.escrow_refund_tx_hash,
           refundable_after_days: 30,
           url: report_page(refunded.id)
         }}

      {:error, failure} ->
        report_refusal(failure, PriorityRefund, "ask its money back")
    end
  end

  # Naming the wallet

  defp wallet_address(wallet) when is_binary(wallet) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, wallet),
      do: {:ok, String.downcase(wallet)},
      else: {:error, {:invalid, [@wallet_shape]}}
  end

  # A read names a wallet that already acted; it makes no profile for one that
  # never did, and a wallet with no profile has no payments to read.
  defp wallet_profile(wallet) do
    case Identity.get_wallet_profile(8453, wallet) do
      {:ok, profile} ->
        active(profile)

      {:error, failure} ->
        if Purchase.missing?(failure), do: {:error, :not_found}, else: {:error, failure}
    end
  end

  # A suspended profile keeps its page and loses this door, as it loses the
  # command-line one.
  defp active(%{status: :active} = profile), do: {:ok, profile}
  defp active(_suspended), do: {:error, :suspended}

  defp payment(meta) do
    case X402.MCP.fetch_payment(%{"_meta" => meta}) do
      {:ok, payment} -> payment
      :error -> nil
    end
  end

  # Paying for a report

  defp purchase_answer({:payment_required, found}),
    do: {:payment_required, Purchase.terms(found, @challenge_error), handoff(found)}

  defp purchase_answer({:payment_rejected, found, reason}),
    do:
      {:payment_required, Purchase.terms(found, reason), Map.put(handoff(found), :reason, reason)}

  defp purchase_answer({:applied, found, receipt}) do
    answer =
      Purchase.payment_help(%{
        status: "applied",
        payment_intent_id: found.id,
        receipt: Purchase.receipt_payload(receipt),
        amount_usdc: USDC.format(found.amount_atomic),
        effect_summary: found.effect_summary
      })

    {:paid, Map.merge(answer, Purchase.applied_effect(found)), receipt.payment_response}
  end

  defp purchase_answer({:settled, found, receipt}),
    do: {:paid, status_answer(%{found | receipt: receipt}), receipt.payment_response}

  defp purchase_answer({:settlement_pending, found}) do
    {:error,
     Purchase.payment_help(%{
       problem_code: "settlement_pending",
       status: "settlement_pending",
       payment_intent_id: found.id,
       next_action:
         "Do not pay again. This payment is being confirmed with the payment service by hand; read get_payment_status."
     })}
  end

  defp purchase_answer({:expired, found}) do
    {:error,
     Purchase.payment_help(%{
       problem_code: "expired",
       status: "expired",
       payment_intent_id: found.id,
       next_action:
         "These terms are no longer on offer. Call this tool again to be given fresh ones."
     })}
  end

  defp purchase_answer({:facilitator_unavailable, found, reason}) do
    {:error,
     Purchase.payment_help(%{
       problem_code: "facilitator_unavailable",
       status: "facilitator_unavailable",
       payment_intent_id: found.id,
       reason: reason,
       next_action:
         "Do not pay again. Send the same signed payment again, or read get_payment_status."
     })}
  end

  defp purchase_answer({:error, failure}), do: purchase_refusal(failure)

  # What a client that cannot pay over MCP does with the terms: the same
  # purchase, paid from a terminal or read back here, never bought twice.
  defp handoff(found) do
    Purchase.payment_help(%{
      status: "payment_required",
      payment_intent_id: found.id,
      amount_usdc: USDC.format(found.amount_atomic),
      escrow_address: Map.fetch!(found.payload, "pay_to_address"),
      expires_at: found.expires_at,
      next_action:
        "Sign the terms with the wallet named in wallet_address and call this tool again with the same arguments and the signed payment in _meta[\"x402/payment\"]. Calling again before expires_at returns these same terms; never pay twice.",
      if_your_client_cannot_pay:
        "Pay this same payment intent from a terminal with the command-line client, `patchbay payments execute #{found.id}`, signed by the same wallet; then read get_payment_status with payment_intent_id and wallet_address.",
      status_tool: "get_payment_status",
      status_url: Purchase.show_url(found)
    })
  end

  defp status_answer(found) do
    Purchase.intent_payload(found)
    |> Map.merge(Purchase.recovery_payload(found))
    |> Map.put(:payment_intent_id, found.id)
  end

  defp purchase_refusal(:not_found) do
    {:error,
     %{
       problem_code: "not_found",
       error: "There is no payment intent with that id for the wallet named."
     }}
  end

  defp purchase_refusal(:suspended), do: {:error, @suspended}

  defp purchase_refusal(:not_configured) do
    {:error,
     Purchase.payment_help(%{
       problem_code: "not_configured",
       error: @not_set_up,
       next_action: "Use the free Patchbay tools. Payments are not enabled on this deployment."
     })}
  end

  defp purchase_refusal({:invalid, messages}),
    do: {:error, %{problem_code: "invalid", errors: messages}}

  defp purchase_refusal(%Ash.Error.Forbidden{}),
    do:
      {:error,
       %{problem_code: "forbidden", error: "That payment intent belongs to someone else."}}

  defp purchase_refusal(error),
    do: purchase_refusal({:invalid, Purchase.refusal_messages(error)})

  # Proving the wallet for an action that moves money without a payment

  # Without a challenge and signature, the answer is what to sign. With both,
  # the signature has to be the named wallet's over this server's challenge for
  # exactly this action, and the wallet has to have a profile: only the one
  # that paid for the report gets past the report's own rules after that.
  defp proven(arguments, name, report_id, reply_id, act) do
    with {:ok, wallet} <- wallet_address(arguments["wallet_address"]),
         :ok <- ids(report_id, reply_id) do
      action = %{action: name, report_id: report_id, reply_id: reply_id, wallet: wallet}
      proof(action, Map.take(arguments, ["challenge", "signature"]), act)
    end
  end

  # The challenge carries the ids as given, so only ids shaped like a report's
  # and a reply's get one; nothing is issued or signed for an id that cannot
  # name anything.
  defp ids(report_id, reply_id) do
    named = Enum.reject([report_id, reply_id], &(&1 == ""))

    if Enum.all?(named, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))),
      do: :ok,
      else: {:error, :not_found}
  end

  defp proof(action, %{"challenge" => challenge, "signature" => signature}, act) do
    with :ok <- WalletProof.verify(action, challenge, signature),
         {:ok, actor} <- payer_profile(action.wallet) do
      act.(actor)
    end
  end

  defp proof(action, unsigned, _act) when map_size(unsigned) == 0,
    do: {:error, {:sign, WalletProof.challenge(action)}}

  defp proof(_action, _one_without_the_other, _act),
    do:
      {:error,
       {:invalid, ["challenge and signature: send both, or neither to be given a challenge"]}}

  # A wallet with no profile never paid for anything, so it is not this
  # report's payer, whichever report it names.
  defp payer_profile(wallet) do
    case wallet_profile(wallet) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:error, %Ash.Error.Forbidden{}}
      {:error, failure} -> {:error, failure}
    end
  end

  defp report_refusal({:sign, %{challenge: challenge, typed_data: typed_data}}, _process, _act) do
    {:error,
     %{
       problem_code: "signature_required",
       status: "sign_to_continue",
       challenge: challenge,
       typed_data: typed_data,
       challenge_expires_in_seconds: WalletProof.max_age_seconds(),
       next_action:
         "Have the wallet named in wallet_address sign typed_data (eth_signTypedData_v4), then call this tool again with the same arguments plus challenge and signature. Nothing has happened yet."
     }}
  end

  defp report_refusal({:invalid, messages}, _process, _act),
    do: {:error, %{problem_code: "invalid", errors: messages}}

  defp report_refusal(:challenge_expired, _process, _act) do
    {:error,
     %{
       problem_code: "challenge_expired",
       error:
         "That challenge has expired. Call again without challenge and signature for a fresh one."
     }}
  end

  defp report_refusal(:challenge_mismatch, _process, _act) do
    {:error,
     %{
       problem_code: "challenge_mismatch",
       error:
         "That challenge was not issued for this action, report, reply and wallet. Call again without challenge and signature for one that is."
     }}
  end

  defp report_refusal(:signature_unreadable, _process, _act),
    do:
      {:error,
       %{
         problem_code: "invalid",
         errors: ["signature: could not be read as an EIP-712 signature"]
       }}

  defp report_refusal(:other_wallet, _process, _act) do
    {:error,
     %{
       problem_code: "other_wallet",
       error: "That signature was made by a different wallet than wallet_address names."
     }}
  end

  defp report_refusal(:not_found, _process, _act),
    do: {:error, %{problem_code: "not_found", error: "There is no report with that id."}}

  defp report_refusal(:suspended, _process, _act), do: {:error, @suspended}

  defp report_refusal(%Ash.Error.Forbidden{}, _process, act) do
    {:error,
     %{
       problem_code: "forbidden",
       error: "Only the wallet that paid for this report can #{act}."
     }}
  end

  defp report_refusal(error, process, act) do
    if process.missing?(error),
      do: report_refusal(:not_found, process, act),
      else: report_refusal({:invalid, Refusal.messages(error)}, process, act)
  end

  defp report_page(id), do: MD.absolute("/reports/#{id}")
end
