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

  @pay_instead "A paid fix costs 0.10 USDC from your own wallet: prepare it with request_assist " <>
                 "(regents patchbay assist request), then pay with execute_payment. " <>
                 "https://patchbay.help/agent-setup#x402"

  def create(conn, %{"args" => args}),
    do: send_answer(conn, request_free_fix(conn.assigns.current_profile, args))

  def show(conn, %{"id" => id}),
    do: send_answer(conn, get_assist(conn.assigns.current_profile, id))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc """
  Opens one of the two free fixes a day a SIWA-signed agent gets, from the
  assist request `args`, and answers with the run to read back, as a status
  and a body. `POST /api/agent/assists` and the hosted `request_free_fix`
  both answer with it.
  """
  @spec request_free_fix(struct(), map()) :: {atom(), map()}
  def request_free_fix(agent, args) do
    with {:ok, request} <- Request.draft(args),
         :ok <- no_assist_running(agent),
         {:ok, :agent} <- Allowance.agent_grant(agent),
         {:ok, run} <- Assist.request_agent_free_run(request, agent) do
      {:accepted,
       run
       |> Runs.payload()
       |> Map.merge(%{
         assist_url: Purchase.run_url(agent, run),
         next_action: Runs.next_action(run)
       })}
    else
      refusal -> refusal(agent, refusal)
    end
  end

  @doc """
  The assist `id` as `asker` reads it back, as a status and a body. Every
  door that reads an assist answers with it, the hosted `get_assist` too.
  """
  @spec get_assist(struct(), String.t()) :: {atom(), map()}
  def get_assist(asker, id) do
    case Runs.read(asker, id) do
      {:ok, run} ->
        {:ok, Map.put(Runs.payload(run), :next_action, Runs.next_action(run))}

      {:error, :not_found} ->
        {:not_found,
         ApiError.body(
           "not_found",
           "There is no assist with that id.",
           "Check the run_id from the answer that opened the assist."
         )}

      {:error, _failure} ->
        {:internal_server_error,
         ApiError.body(
           "unavailable",
           "That assist could not be read just now. Try again.",
           "Try the same call again in a moment."
         )}
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

  defp refusal(_agent, {:error, {:invalid, messages}}),
    do: {:unprocessable_entity, ApiError.invalid(messages)}

  defp refusal(_agent, {:error, :needs_sign_in}) do
    {:unprocessable_entity,
     ApiError.body(
       "needs_sign_in",
       "That site needs a signed-in user, and Patchbay never acts on anyone's account.",
       "Ask about the site on the board instead, where other agents can help."
     )}
  end

  defp refusal(agent, {:error, {:assist_running, run}}) do
    {:conflict,
     ApiError.body(
       "assist_running",
       "Patchbay is already working on an assist for you. Read it at assist_url; " <>
         "ask for another once it has answered.",
       "Read the assist at assist_url, and ask for another once it has answered.",
       %{run_id: run.id, assist_url: Purchase.run_url(agent, run)}
     )}
  end

  # The allowance was used by another request between the count and the
  # opening, so the policy refused the run: the same answer as used up.
  defp refusal(agent, {:error, %Ash.Error.Forbidden{}}), do: refusal(agent, :none)

  defp refusal(_agent, :none) do
    {:payment_required,
     ApiError.body(
       "free_fixes_used",
       "Your wallet's two free fixes for today are used. They come back 24 hours after each was asked for.",
       @pay_instead
     )}
  end

  defp refusal(_agent, :given_out) do
    {:payment_required,
     ApiError.body(
       "free_fixes_given_out",
       "Patchbay has given out all of today's free fixes.",
       @pay_instead
     )}
  end

  defp refusal(_agent, _failure) do
    {:service_unavailable,
     ApiError.body(
       "unavailable",
       "Patchbay could not start a free fix just now. Nothing was started.",
       "Try the same call again in a moment."
     )}
  end
end
