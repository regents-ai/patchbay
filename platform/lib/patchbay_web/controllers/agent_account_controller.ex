defmodule PatchbayWeb.AgentAccountController do
  @moduledoc "The shared Points read for a signed, currently paired agent; no wallet writes."
  use PatchbayWeb, :controller

  alias PatchbayWeb.UnexpectedFailure
  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."

  def points(conn, _params), do: send_answer(conn, account_points(conn.assigns.agent_actor))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc """
  `actor`'s person's Points as decimal text, as the Points page shows them,
  as a status and a body: `GET /tools/account/points` and the
  `account_points` tool. While earning is off, the daily limits are left
  empty, as on the Points page.
  """
  @spec account_points(Patchbay.Agents.Actor.t()) :: {atom(), map()}
  def account_points(actor) do
    case RegentPoints.summary(actor: actor) do
      {:ok, summary} ->
        earning_off? = Rules.active() == []

        answer = %{
          points: Amount.format(summary.balance_micro),
          earned_today: Amount.format(summary.earned_today_micro),
          pending: summary.pending,
          daily_allowances: daily_allowances(summary.allowances, earning_off?),
          entries:
            Enum.map(
              summary.entries,
              &%{
                points: Amount.format(&1.points_micro_delta),
                source: &1.source_app,
                by: &1.actor_kind,
                earned_at: &1.earned_at
              }
            ),
          more: summary.more?
        }

        {:ok, with_points_note(answer, earning_off?)}

      {:error, error} ->
        UnexpectedFailure.log(error)
        unavailable()
    end
  end

  defp daily_allowances(_allowances, true), do: []

  defp daily_allowances(allowances, false),
    do: Enum.map(allowances, &%{scope: &1.scope, remaining: Amount.format(&1.remaining)})

  defp with_points_note(answer, true), do: Map.put(answer, :note, @points_off)
  defp with_points_note(answer, false), do: answer

  defp unavailable,
    do:
      {:service_unavailable,
       PatchbayWeb.ApiError.body(
         "unavailable",
         "This account read is unavailable.",
         "Try again with fresh proof."
       )}
end
