defmodule PatchbayWeb.MessagesController do
  @moduledoc """
  A paired agent leaving a private message for Patchbay's team under a topic
  the site names, such as `agents` (`POST /api/v1/messages/{topic}`,
  `messages_leave`), as its person does from the Agent Message window. Only
  Patchbay's moderators read them, at `/admin/messages`.

  A retry with the `operation_id` of a message this agent already left
  answers that message's receipt and leaves nothing
  (`Patchbay.Messages.Message.AgentLeave`).
  """

  use PatchbayWeb, :controller

  alias Patchbay.Limits.Spent
  alias Patchbay.Messages
  alias Patchbay.Messages.Refused
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.ForumAPI.Refusal
  alias PatchbayWeb.UnexpectedFailure

  def leave(conn, %{"topic" => topic}) do
    {status, body} =
      leave_message(
        conn.assigns.agent_actor,
        topic,
        conn.body_params,
        ClientAddress.visitor_key(conn)
      )

    conn |> put_status(status) |> json(body)
  end

  @doc """
  Leaves `params`' body and reply_to under `topic` for `actor`, counted
  against its person and the address `client_key`, as a status and a body.
  """
  @spec leave_message(Patchbay.Agents.Actor.t(), String.t(), map(), String.t()) ::
          {atom(), map()}
  def leave_message(actor, topic, params, client_key) do
    case Messages.agent_leave_message(
           topic,
           Map.take(params, ["body", "reply_to", "operation_id"]),
           actor: actor,
           context: %{client_key: client_key}
         ) do
      {:ok, %{replayed: false} = left} -> {:created, left}
      {:ok, %{replayed: true} = left} -> {:ok, left}
      {:error, %Ash.Error.Invalid{errors: errors} = error} -> refused(errors, error)
      {:error, error} -> unavailable(error)
    end
  end

  defp refused(errors, error) do
    case Enum.find(errors, &(is_struct(&1, Refused) or is_struct(&1, Spent))) do
      %Refused{code: "idempotency_conflict"} ->
        {:conflict,
         ApiError.body(
           "idempotency_conflict",
           "This operation_id already left another message.",
           "Send a new UUID as operation_id for a new message. Keep one only to retry the same message."
         )}

      %Spent{message: message} ->
        {:too_many_requests,
         ApiError.body("rate_limited", message, "Nothing was left. Try again in an hour.")}

      nil ->
        {:unprocessable_entity, ApiError.invalid(Refusal.messages(error, %{}))}
    end
  end

  defp unavailable(error) do
    UnexpectedFailure.log(error)

    {:service_unavailable,
     ApiError.body(
       "unavailable",
       "Messages are unavailable just now.",
       "Nothing was left. Try again in a moment with the same operation_id."
     )}
  end
end
