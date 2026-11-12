defmodule Patchbay.Messages.Message.AgentLeave do
  @moduledoc """
  An agent's message, the same on every surface: `%{receipt: Message.receipt/1,
  replayed: boolean}`.

  One agent uses an `operation_id` once, which the table's own unique index
  holds (`:agent_operation`). A reuse with the same topic, text and reply_to
  answers the receipt of the message it left (`replayed: true`) and leaves
  nothing; a reuse with any other is refused as `idempotency_conflict`. Of two
  calls with one key at once, the second's write is refused by the index, and
  it answers as a reuse.

  Every caller passes the client address as `context: %{client_key: key}`,
  which the message's allowances count (`Patchbay.Limits.LimitWrites`).
  """

  use Ash.Resource.Actions.Implementation

  alias Patchbay.Agents.Actor
  alias Patchbay.Messages
  alias Patchbay.Messages.{Message, Refused}

  @system %{role: :system}

  @impl true
  def run(input, _opts, %{actor: %Actor{} = actor}) do
    wanted = Map.take(input.arguments, [:topic, :body, :reply_to, :operation_id])

    case left(actor, wanted.operation_id) do
      {:ok, nil} -> leave(wanted, actor, input.context)
      {:ok, message} -> reuse(message, wanted)
      {:error, error} -> {:error, error}
    end
  end

  defp leave(wanted, actor, context) do
    case Messages.leave_message(Map.take(wanted, [:topic, :body, :reply_to]),
           actor: actor,
           private_arguments: %{operation_id: wanted.operation_id},
           context: %{client_key: Map.fetch!(context, :client_key)}
         ) do
      {:ok, message} -> {:ok, %{receipt: Message.receipt(message), replayed: false}}
      {:error, error} -> answer_used(error, actor, wanted)
    end
  end

  # The key was used by a call that committed while this one was on its way.
  defp answer_used(error, actor, wanted) do
    with true <- key_used?(error),
         {:ok, %Message{} = message} <- left(actor, wanted.operation_id) do
      reuse(message, wanted)
    else
      _other -> {:error, error}
    end
  end

  defp key_used?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%{field: :agent_profile_id}, &1))

  defp key_used?(_error), do: false

  defp left(actor, key), do: Messages.get_agent_message(actor.id, key, actor: @system)

  defp reuse(message, wanted) do
    if {message.topic, message.body, message.reply_to} ==
         {wanted.topic, wanted.body, wanted[:reply_to]},
       do: {:ok, %{receipt: Message.receipt(message), replayed: true}},
       else: {:error, Refused.exception(code: "idempotency_conflict")}
  end
end
