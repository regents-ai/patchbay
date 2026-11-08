defmodule Patchbay.Forum.SolutionAccept do
  @moduledoc """
  The asker of a paid priority report names the reply that answered it, and
  the money held for the report goes to that reply's author.

  Nothing a caller sends names the asker: the actor is whoever the door
  verified, a profile signed in on a page or the wallet that paid, proven by
  its signature. The report is held under a row lock while the reply is
  checked and marked, so two accepts arriving at once cannot both get
  through. The payout is queued in the same transaction as the mark and sent
  by its job (`Patchbay.Escrow.Send`); one accepted before Base confirmed the
  bounty is paid once it has.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @doc """
  Marks `reply_id` as the answer to `report_id` for `actor`, which queues the
  payout. The report comes back as it stands afterwards, with the accepted
  reply and its author loaded.
  """
  @spec run(String.t(), String.t() | nil, struct() | nil) ::
          {:ok, Report.t()} | {:error, term()}
  def run(report_id, reply_id, actor) do
    case Ash.transact([Report], fn -> mark(actor, report_id, reply_id) end) do
      {:ok, {:ok, accepted}} -> {:ok, accepted}
      {:error, failure} -> {:error, failure}
    end
  end

  # The check and the mark happen under one row lock, so a second accept that
  # arrives while the first is being written waits for it and is then refused.
  defp mark(actor, id, reply_id) do
    with {:ok, report} <- locked_report(actor, id) do
      Forum.accept_reply(report, reply_id, actor: actor, load: [accepted_reply: [:author]])
    end
  end

  defp locked_report(actor, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found_or_missing(Forum.lock_report(uuid, actor: actor))
      :error -> {:error, :not_found}
    end
  end

  defp found_or_missing({:ok, nil}), do: {:error, :not_found}
  defp found_or_missing({:ok, record}), do: {:ok, record}

  defp found_or_missing({:error, error}) do
    if missing?(error), do: {:error, :not_found}, else: {:error, error}
  end

  @doc "Whether an error means there is no such report."
  @spec missing?(term()) :: boolean()
  def missing?(%Ash.Error.Query.NotFound{}), do: true
  def missing?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &missing?/1)
  def missing?(_error), do: false
end
