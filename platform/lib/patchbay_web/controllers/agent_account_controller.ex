defmodule PatchbayWeb.AgentAccountController do
  @moduledoc "Shared account reads for a signed, currently paired agent; no grant or wallet writes."
  use PatchbayWeb, :controller

  alias PatchbayWeb.UnexpectedFailure
  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."

  def balances(conn, _params), do: send_answer(conn, account_balances(conn.assigns.agent_actor))

  def credits_history(conn, _params),
    do: send_answer(conn, account_credits_history(conn.assigns.agent_actor, conn.body_params))

  def points(conn, _params), do: send_answer(conn, account_points(conn.assigns.agent_actor))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc """
  `actor`'s person's Credits and its own spending grant, as a status and a
  body: `GET /tools/account/balances` and the `account_balances` tool.
  """
  @spec account_balances(Patchbay.Agents.Actor.t()) :: {atom(), map()}
  def account_balances(actor) do
    credit_actor = credit_actor(actor)

    permission =
      RegentCredits.agent_permissions!(actor: credit_actor)
      |> Enum.find(
        &(&1.agent_address == credit_actor.agent_address and
            &1.pairing_id == credit_actor.pairing_id)
      )

    budget =
      if permission do
        Map.take(permission, [:enabled, :max_per_spend, :daily_limit, :sites])
        |> Map.put(:enabled, permission.enabled and RegentCredits.agent_grants_enabled?())
        |> Map.put(:used_24h, RegentCredits.AgentSpending.spent_today(credit_actor))
      else
        %{enabled: false}
      end

    {:ok,
     %{
       account_id: actor.human_account_id,
       pairing_id: credit_actor.pairing_id,
       credits: RegentCredits.balance(credit_actor.privy_user_id),
       spending_grant: budget
     }}
  end

  @doc """
  One page of `actor`'s person's Credits history after the cursor `params`
  may carry, as a status and a body: `POST /tools/account/credits/history`
  and the `account_credits_history` tool.
  """
  @spec account_credits_history(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def account_credits_history(_actor, %{"after" => cursor}) when not is_binary(cursor),
    do: invalid_cursor()

  def account_credits_history(actor, params) do
    args =
      case params do
        %{"after" => cursor} -> %{after: cursor}
        _ -> %{}
      end

    case RegentCredits.history(args, actor: credit_actor(actor)) do
      {:ok, history} ->
        {:ok,
         %{
           entries: history.entries,
           pagination: %{has_more: history.more?, next_cursor: history.next}
         }}

      {:error, error} ->
        if cursor_error?(error) do
          invalid_cursor()
        else
          UnexpectedFailure.log(error)
          unavailable()
        end
    end
  end

  defp cursor_error?(%Ash.Error.Action.InvalidArgument{field: :after}), do: true
  defp cursor_error?(%Ash.Error.Page.InvalidKeyset{}), do: true

  defp cursor_error?(%Ash.Error.Invalid{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &cursor_error?/1)

  defp cursor_error?(_error), do: false

  defp invalid_cursor do
    {:unprocessable_entity,
     PatchbayWeb.ApiError.body(
       "invalid_cursor",
       "That history cursor is invalid.",
       "Send after as the previous page's pagination.next_cursor, unchanged, or omit it for the newest entries."
     )}
  end

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

  defp credit_actor(actor) do
    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      "patchbay",
      actor.pairing_id
    )
  end

  defp unavailable,
    do:
      {:service_unavailable,
       PatchbayWeb.ApiError.body(
         "unavailable",
         "This account read is unavailable.",
         "Try again with fresh proof."
       )}
end
