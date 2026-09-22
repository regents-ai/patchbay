defmodule PatchbayWeb.AssistAPI.Runs do
  @moduledoc """
  Reading a paid assist back, whichever door the payer came through, and the
  JSON shape every door answers it in.
  """

  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias PatchbayWeb.PaymentsAPI.Purchase

  @doc "The run `id` as it stands, if it is `actor`'s."
  @spec read(struct(), String.t()) :: {:ok, Run.t()} | {:error, :not_found | term()}
  def read(actor, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found_or_missing(Assist.get_run(uuid, actor: actor))
      :error -> {:error, :not_found}
    end
  end

  @doc "The run as its payer reads it: the request, where it stands, and what was tried."
  @spec payload(Run.t()) :: map()
  def payload(run) do
    %{
      run_id: run.id,
      status: run.status,
      outcome: run.outcome,
      goal: run.goal,
      site_url: run.site_url,
      sign_in: run.sign_in,
      expected_result: run.expected_result,
      believed_calls: run.believed_calls,
      steps: run.steps,
      payment_intent_id: run.payment_intent_id,
      requested_at: run.inserted_at,
      started_at: run.started_at,
      finished_at: run.finished_at,
      updated_at: run.updated_at,
      fee_deposit: %{status: run.deposit_status, tx_hash: run.deposit_tx_hash}
    }
  end

  @doc "What the payer should do next, given where the run stands."
  @spec next_action(Run.t()) :: String.t()
  def next_action(%{status: :finished}),
    do: "Patchbay has answered; the outcome and the steps say what it found. Do not pay again."

  def next_action(%{status: :failed}),
    do:
      "Patchbay could not finish this assist. A person at Patchbay will look at it. Do not pay again."

  def next_action(%{status: :assessment_pending}),
    do:
      "Patchbay's helper was unavailable; a person at Patchbay will finish this assist. " <>
        "The payment stands; read this again later. Do not pay again."

  def next_action(_open),
    do:
      "Payment received. Patchbay is working on it; read this again after a short wait. Do not pay again."

  # Ash filters out other payers' runs; a denied read reveals neither the
  # record nor its existence. Any other failure is reported as itself.
  defp found_or_missing({:ok, %Run{} = run}), do: {:ok, run}
  defp found_or_missing({:ok, nil}), do: {:error, :not_found}

  defp found_or_missing({:error, error}) do
    if Purchase.missing?(error), do: {:error, :not_found}, else: {:error, error}
  end
end
