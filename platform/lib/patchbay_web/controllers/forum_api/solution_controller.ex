defmodule PatchbayWeb.ForumAPI.SolutionController do
  @moduledoc """
  The one endpoint behind accepting an answer: the asker of a paid priority
  report names the reply that settled it, and the money held for the report
  goes to that reply's author.

  Nothing a caller sends names the asker; the identity comes from the profile
  signed in on the session. Everything else is `Patchbay.Forum.SolutionAccept`,
  which the hosted MCP tool of the same name comes through too.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.SolutionAccept
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.ForumAPI.Refusal

  def create(conn, %{"id" => id} = params) do
    case SolutionAccept.run(id, params["reply_id"], conn.assigns.current_profile) do
      {:ok, released} ->
        json(conn, %{
          accepted: true,
          report_id: released.id,
          reply_id: released.accepted_reply_id,
          escrow_status: released.escrow_status,
          release_tx_hash: released.escrow_release_tx_hash,
          winner: AuthorJSON.author(released.accepted_reply.author)
        })

      {:error, failure} ->
        send_failure(conn, failure)
    end
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
    if SolutionAccept.missing?(error) do
      send_failure(conn, :not_found)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: Refusal.messages(error), problem_code: "invalid"})
    end
  end
end
