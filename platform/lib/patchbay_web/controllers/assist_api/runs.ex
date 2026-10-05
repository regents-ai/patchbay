defmodule PatchbayWeb.AssistAPI.Runs do
  @moduledoc """
  Reading a paid assist back, whichever door the payer came through, and the
  JSON shape every door answers it in.
  """

  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias PatchbayWeb.KnownFixAnswer

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
      error: run.error,
      site_url: run.site_url,
      sign_in: run.sign_in,
      believed_calls: run.believed_calls,
      known_fix: known_fix(run),
      steps: run.steps,
      payment_intent_id: run.payment_intent_id,
      requested_at: run.inserted_at,
      started_at: run.started_at,
      finished_at: run.finished_at,
      updated_at: run.updated_at,
      fee_deposit: %{status: run.deposit_status, tx_hash: run.deposit_tx_hash}
    }
  end

  defp known_fix(run) do
    case KnownFixAnswer.for_run(run) do
      nil -> nil
      answer -> KnownFixAnswer.json(answer)
    end
  end

  @doc """
  What the asker should do next, given where the run stands and whether it
  was paid for or free.
  """
  @spec next_action(Run.t()) :: String.t()
  def next_action(%{status: :finished} = run),
    do: "Patchbay has answered; the outcome and the steps say what it found." <> paid_once(run)

  def next_action(%{status: :failed} = run),
    do:
      "Patchbay could not finish this assist. A person at Patchbay will look at it." <>
        paid_once(run)

  def next_action(%{status: :assessment_pending, grant: :paid}),
    do:
      "Patchbay's helper was unavailable; a person at Patchbay will finish this assist. " <>
        "The payment stands; read this again later. Do not pay again."

  def next_action(%{status: :assessment_pending}),
    do:
      "Patchbay's helper was unavailable; a person at Patchbay will finish this assist. " <>
        "Read this again later."

  def next_action(%{grant: :paid}),
    do:
      "Payment received. Patchbay is working on it; read this again after a short wait. Do not pay again."

  def next_action(_free),
    do: "Patchbay is working on this free fix; read this again after a short wait."

  defp paid_once(%{grant: :paid}), do: " Do not pay again."
  defp paid_once(_free), do: ""

  # Ash filters out other payers' runs; a denied read reveals neither the
  # record nor its existence. Any other failure is reported as itself.
  defp found_or_missing({:ok, %Run{} = run}), do: {:ok, run}
  defp found_or_missing({:ok, nil}), do: {:error, :not_found}

  defp found_or_missing({:error, error}) do
    if RegentPayments.Purchase.missing?(error), do: {:error, :not_found}, else: {:error, error}
  end
end
