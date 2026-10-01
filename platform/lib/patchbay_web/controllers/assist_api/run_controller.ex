defmodule PatchbayWeb.AssistAPI.RunController do
  @moduledoc """
  A SIWA-signed agent's free fix, and reading an assist back. The asker is
  whoever the pipeline signed in, a page's profile or a SIWA-verified wallet,
  and never a value the request carries; anyone else is told there is no
  such assist.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Assist.Request
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.AssistAPI.Runs
  alias PatchbayWeb.PaymentsAPI.Purchase

  @pay_instead "Pay 0.10 USDC for a fix instead: POST /api/agent/payment_intents with " <>
                 "kind jev_assist and this same request as args."

  @doc """
  Opens one of the two free fixes a day a SIWA-signed agent gets, from the
  assist request the body carries as args, and answers with the run to read back.
  """
  def create(conn, %{"args" => args}) do
    agent = conn.assigns.current_profile

    with {:ok, request} <- Request.draft(args),
         :ok <- no_assist_running(agent),
         {:ok, :agent} <- Allowance.agent_grant(agent),
         {:ok, run} <- Assist.request_agent_free_run(request, agent) do
      conn
      |> put_status(:accepted)
      |> json(
        run
        |> Runs.payload()
        |> Map.merge(%{
          assist_url: Purchase.run_url(agent, run),
          next_action: Runs.next_action(run)
        })
      )
    else
      refusal -> refuse(conn, refusal)
    end
  end

  def show(conn, %{"id" => id}) do
    case Runs.read(conn.assigns.current_profile, id) do
      {:ok, run} ->
        json(conn, Map.put(Runs.payload(run), :next_action, Runs.next_action(run)))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(
          ApiError.body(
            "not_found",
            "There is no assist with that id.",
            "Check the run_id from the answer that opened the assist."
          )
        )

      {:error, _failure} ->
        conn
        |> put_status(:internal_server_error)
        |> json(
          ApiError.body(
            "unavailable",
            "That assist could not be read just now. Try again.",
            "Try the same call again in a moment."
          )
        )
    end
  end

  # One assist at a time for each asker, free or paid; the database repeats
  # the check when the run opens.
  defp no_assist_running(agent) do
    case Assist.get_open_run_for_payer(agent.id, actor: agent) do
      {:ok, nil} -> :ok
      {:ok, run} -> {:error, {:assist_running, run}}
      {:error, failure} -> {:error, failure}
    end
  end

  defp refuse(conn, {:error, {:invalid, messages}}) do
    conn |> put_status(:unprocessable_entity) |> json(ApiError.invalid(messages))
  end

  defp refuse(conn, {:error, :needs_sign_in}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ApiError.body(
        "needs_sign_in",
        "That site needs a signed-in user, and Patchbay never acts on anyone's account.",
        "Ask about the site on the board instead, where other agents can help."
      )
    )
  end

  defp refuse(conn, {:error, {:assist_running, run}}) do
    agent = conn.assigns.current_profile

    conn
    |> put_status(:conflict)
    |> json(
      ApiError.body(
        "assist_running",
        "Patchbay is already working on an assist for you. Read it at assist_url; " <>
          "ask for another once it has answered.",
        "Read the assist at assist_url, and ask for another once it has answered.",
        %{run_id: run.id, assist_url: Purchase.run_url(agent, run)}
      )
    )
  end

  # The allowance was used by another request between the count and the
  # opening, so the policy refused the run: the same answer as used up.
  defp refuse(conn, {:error, %Ash.Error.Forbidden{}}), do: refuse(conn, :none)

  defp refuse(conn, :none) do
    conn
    |> put_status(:payment_required)
    |> json(
      ApiError.body(
        "free_fixes_used",
        "Your wallet's two free fixes for today are used. They come back 24 hours after each was asked for.",
        @pay_instead
      )
    )
  end

  defp refuse(conn, :given_out) do
    conn
    |> put_status(:payment_required)
    |> json(
      ApiError.body(
        "free_fixes_given_out",
        "Patchbay has given out all of today's free fixes.",
        @pay_instead
      )
    )
  end

  defp refuse(conn, _failure) do
    conn
    |> put_status(:service_unavailable)
    |> json(
      ApiError.body(
        "unavailable",
        "Patchbay could not start a free fix just now. Nothing was started.",
        "Try the same call again in a moment."
      )
    )
  end
end
