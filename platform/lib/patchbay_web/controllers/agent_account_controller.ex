defmodule PatchbayWeb.AgentAccountController do
  @moduledoc "Shared account reads for a signed, currently paired agent; no grant or wallet writes."
  use PatchbayWeb, :controller

  alias PatchbayWeb.UnexpectedFailure
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

  def credits_history(%{body_params: %{"after" => cursor}} = conn, _params)
      when not is_binary(cursor),
      do: invalid_cursor(conn)

  def credits_history(conn, _params) do
    args =
      case conn.body_params do
        %{"after" => cursor} when is_binary(cursor) -> %{after: cursor}
        _ -> %{}
      end

    case RegentCredits.history(args, actor: credit_actor(conn)) do
      {:ok, history} ->
        json(conn, %{
          entries: history.entries,
          pagination: %{has_more: history.more?, next_cursor: history.next}
        })

      {:error, error} ->
        if cursor_error?(error) do
          invalid_cursor(conn)
        else
          conn |> UnexpectedFailure.log(error) |> unavailable()
        end
    end
  end

  defp cursor_error?(%Ash.Error.Action.InvalidArgument{field: :after}), do: true
  defp cursor_error?(%Ash.Error.Page.InvalidKeyset{}), do: true

  defp cursor_error?(%Ash.Error.Invalid{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &cursor_error?/1)

  defp cursor_error?(_error), do: false

  defp invalid_cursor(conn) do
    conn
    |> put_status(422)
    |> json(
      PatchbayWeb.ApiError.body(
        "invalid_cursor",
        "That history cursor is invalid.",
        "Send after as the previous page's pagination.next_cursor, unchanged, or omit it for the newest entries."
      )
    )
  end

  # Points as decimal text, as the Points page shows them. While earning is
  # off, the daily limits are left empty, as on the Points page.
  def points(conn, _params) do
    case RegentPoints.summary(actor: conn.assigns.agent_actor) do
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

        json(conn, with_points_note(answer, earning_off?))

      {:error, _} ->
        unavailable(conn)
    end
  end

  defp daily_allowances(_allowances, true), do: []

  defp daily_allowances(allowances, false),
    do: Enum.map(allowances, &%{scope: &1.scope, remaining: Amount.format(&1.remaining)})

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
