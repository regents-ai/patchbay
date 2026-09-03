defmodule PatchbayWeb.ForumAPI.SolutionController do
  @moduledoc """
  The one endpoint behind accepting an answer: the asker of a paid priority
  report names the reply that settled it, and the money held for the report
  goes to that reply's author.

  Nothing a caller sends names the asker; the identity comes from the profile
  signed in on the session. The report is held under a row lock while the
  reply is checked and marked, so two accepts arriving at once cannot both
  get through, and the payout is only sent once the mark is written. A payout
  that does not go through is written on the report for a person to re-run,
  never retried here.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.ForumAPI.Refusal

  def create(conn, %{"id" => id} = params) do
    actor = conn.assigns.current_profile

    with {:ok, accepted} <- accept(actor, id, params["reply_id"]),
         {:ok, released} <- release(accepted) do
      json(conn, %{
        accepted: true,
        report_id: released.id,
        reply_id: released.accepted_reply_id,
        escrow_status: released.escrow_status,
        release_tx_hash: released.escrow_release_tx_hash,
        winner: AuthorJSON.author(accepted.accepted_reply.author)
      })
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  # The check and the mark happen under one row lock, so a second accept that
  # arrives while the first is being written waits for it and is then refused,
  # before anything reaches the chain.
  defp accept(actor, id, reply_id) do
    case Ash.transact([Report], fn -> mark(actor, id, reply_id) end) do
      {:ok, {:ok, accepted}} -> {:ok, accepted}
      {:error, failure} -> {:error, failure}
    end
  end

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

  defp missing?(%Ash.Error.Query.NotFound{}), do: true
  defp missing?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &missing?/1)
  defp missing?(_error), do: false

  # The winner's wallet is the one on the profile that wrote the reply, read
  # now, because that is who the asker chose to pay.
  defp release(accepted) do
    {status, tx_hash} =
      case Escrow.release(accepted.id, accepted.accepted_reply.author.wallet_address) do
        {:ok, tx_hash} -> {:released, tx_hash}
        {:error, _reason} -> {:release_failed, nil}
      end

    # Nothing over HTTP may write what the escrow said; this is the one place
    # that hears it, so the write is made deliberately without an actor.
    Forum.record_escrow_release(
      accepted,
      %{escrow_status: status, escrow_release_tx_hash: tx_hash},
      authorize?: false
    )
  end

  defp send_failure(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "There is no report with that id.", problem_code: "not_found"})
  end

  defp send_failure(conn, %Ash.Error.Forbidden{}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "Only the asker of this report can accept an answer to it.",
      problem_code: "forbidden"
    })
  end

  defp send_failure(conn, error) do
    if missing?(error) do
      send_failure(conn, :not_found)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: Refusal.messages(error), problem_code: "invalid"})
    end
  end
end
