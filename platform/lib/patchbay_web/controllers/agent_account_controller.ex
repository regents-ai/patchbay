defmodule PatchbayWeb.AgentAccountController do
  @moduledoc "Shared account reads for a signed, currently paired agent; no grant or wallet writes."
  use PatchbayWeb, :controller

  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."

  def balances(conn, _params) do
    actor = credit_actor(conn)

    permission =
      RegentCredits.agent_permissions!(actor: actor)
      |> Enum.find(
        &(&1.agent_address == actor.agent_address and &1.pairing_id == actor.pairing_id)
      )

    budget =
      if permission do
        Map.take(permission, [:enabled, :max_per_spend, :daily_limit, :sites])
        |> Map.put(:enabled, permission.enabled and RegentCredits.agent_grants_enabled?())
        |> Map.put(:used_24h, RegentCredits.AgentSpending.spent_today(actor))
      else
        %{enabled: false}
      end

    json(conn, %{
      account_id: conn.assigns.agent_actor.human_account_id,
      pairing_id: actor.pairing_id,
      credits: RegentCredits.balance(actor.privy_user_id),
      spending_grant: budget
    })
  end

  def credits_history(conn, params) do
    case RegentCredits.history(Map.take(params, ["after"]), actor: credit_actor(conn)) do
      {:ok, history} -> json(conn, history)
      {:error, _} -> unavailable(conn)
    end
  end

  # Points as decimal text, as the Points page shows them.
  def points(conn, _params) do
    case RegentPoints.summary(actor: conn.assigns.agent_actor) do
      {:ok, summary} ->
        answer = %{
          points: Amount.format(summary.balance_micro),
          earned_today: Amount.format(summary.earned_today_micro),
          pending: summary.pending,
          daily_allowances:
            Enum.map(
              summary.allowances,
              &%{scope: &1.scope, remaining: Amount.format(&1.remaining)}
            ),
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

        json(conn, with_points_note(answer, Rules.active() == []))

      {:error, _} ->
        unavailable(conn)
    end
  end

  defp with_points_note(answer, true), do: Map.put(answer, :note, @points_off)
  defp with_points_note(answer, false), do: answer

  defp credit_actor(conn) do
    actor = conn.assigns.agent_actor

    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      "patchbay",
      actor.pairing_id
    )
  end

  defp unavailable(conn),
    do:
      conn
      |> put_status(503)
      |> json(
        PatchbayWeb.ApiError.body(
          "unavailable",
          "This account read is unavailable.",
          "Try again with fresh proof."
        )
      )
end
