defmodule Patchbay.Assist.Receipt do
  @moduledoc """
  What happened for one assist, as six separate lines, assembled from the
  records Patchbay already keeps:

    * `payment`: free, or what the payment that bought the run paid, from
      which wallet and in which transaction (the shared payment receipt).
    * `model`: the model that drafted the arguments, its provider, the
      answer's id, the provider's request id and the tokens it used
      (`Patchbay.Assist.ModelCall`), or nil when nothing was drafted.
    * `suggested_action`: the known fix Jev matched and the last tool call
      the run made or suggested (the run's steps).
    * `actual_call`: what the agent then called. Patchbay does not record
      it, so it is always nil in this version.
    * `result`: the agent's own word on the known fix (`report_known_fix`):
      `passed`, `failed` or `not_reported`. It is about the agent's retry
      only, never about the model's answer.
    * `verification`: always `not_checked`. Neither the model's answer nor
      the enclave it ran in is checked here.

  The caller has already read the run as its owner; the records it names
  are read as Patchbay's own.
  """

  alias Patchbay.Assist
  alias Patchbay.Assist.KnownFixes
  alias Patchbay.Assist.ModelCall
  alias Patchbay.Assist.Run
  alias RegentPayments.PaymentReceipt

  require Ash.Query

  @type t :: %{
          payment: map(),
          model: map() | nil,
          suggested_action: map(),
          actual_call: nil,
          result: String.t(),
          verification: String.t()
        }

  @doc "The receipt for `run`, which the caller has read as its owner."
  @spec for_run(Run.t()) :: t()
  def for_run(%Run{} = run) do
    %{
      payment: payment(run),
      model: model(run),
      suggested_action: suggested_action(run),
      actual_call: nil,
      result: result(run),
      verification: "not_checked"
    }
  end

  defp payment(%Run{grant: :paid, payment_intent_id: intent_id}) do
    # Patchbay's own read of the receipt its own run names.
    paid =
      PaymentReceipt
      |> Ash.Query.filter(payment_intent_id == ^intent_id)
      |> Ash.read_one!(authorize?: false)

    %{
      paid: true,
      payment_intent_id: intent_id,
      amount_usdc: paid && usdc(paid.amount_atomic),
      wallet: paid && paid.payer_address,
      transaction: paid && paid.transaction_hash
    }
  end

  defp payment(_free), do: %{paid: false}

  defp usdc(atomic),
    do:
      atomic |> Decimal.new() |> Decimal.div(1_000_000) |> Decimal.round(2) |> Decimal.to_string()

  defp model(run) do
    # Same: the run's own drafts, newest first.
    ModelCall
    |> Ash.Query.filter(assist_run_id == ^run.id and purpose == :draft_arguments)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        nil

      call ->
        Map.take(call, [
          :provider,
          :model,
          :outcome,
          :response_id,
          :request_id,
          :prompt_tokens,
          :completion_tokens
        ])
    end
  end

  defp suggested_action(run) do
    %{
      known_fix: known_fix_title(known_fix(run)),
      call:
        run.steps
        |> Enum.filter(&is_binary(&1["tool"]))
        |> List.last()
        |> tool_call()
    }
  end

  defp known_fix(run),
    do: Enum.find_value(run.steps, fn step -> is_map(step["known_fix"]) && step["known_fix"] end)

  defp known_fix_title(%{"fix" => choice}) do
    case KnownFixes.get(choice) do
      %{title: title} -> title
      nil -> nil
    end
  end

  defp known_fix_title(nil), do: nil

  defp tool_call(nil), do: nil

  defp tool_call(step),
    do: %{
      tool: step["tool"],
      arguments: step["arguments"],
      called_by_patchbay: step["call"] == "made"
    }

  defp result(run) do
    with %{"decision_id" => id} <- known_fix(run),
         # Same: the decision the run's own step names.
         {:ok, %{result: reported}} when not is_nil(reported) <-
           Assist.get_decision(id, authorize?: false) do
      if reported == :worked, do: "passed", else: "failed"
    else
      _unreported -> "not_reported"
    end
  end
end
