defmodule PatchbayWeb.AgentAccountController do
  @moduledoc "The shared Points read for a signed, currently paired agent; no wallet writes."
  use PatchbayWeb, :controller

  alias Patchbay.Points.Board
  alias Patchbay.SharedReading
  alias PatchbayWeb.{PointsEntries, UnexpectedFailure}
  alias RegentPoints.Rules

  @points_off "Earning Points is off on this site."

  def points(conn, _params), do: send_answer(conn, account_points(conn.assigns.agent_actor))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc """
  `actor`'s person's Points as decimal text, the same figures the Points page
  shows (`PatchbayWeb.PointsEntries.answer/4`), as a status and a body:
  `GET /tools/account/points` and the `account_points` tool. While the page
  would show the board as not read, the whole answer is unavailable.
  """
  @spec account_points(Patchbay.Agents.Actor.t()) :: {atom(), map()}
  def account_points(actor) do
    with {:ok, summary} <- RegentPoints.summary(actor: actor),
         {:ok, %{reading: %{} = board}} <- SharedReading.fetch(Board.key()) do
      earning = Rules.active()
      answer = PointsEntries.answer(summary, board, actor.human_account_id, earning != [])
      {:ok, with_points_note(answer, earning)}
    else
      {:error, error} ->
        UnexpectedFailure.log(error)
        unavailable()

      _board_not_read ->
        unavailable()
    end
  end

  defp with_points_note(answer, []), do: Map.put(answer, :note, @points_off)
  defp with_points_note(answer, _earning), do: answer

  defp unavailable,
    do:
      {:service_unavailable,
       PatchbayWeb.ApiError.body(
         "unavailable",
         "This account read is unavailable.",
         "Try again with fresh proof."
       )}
end
