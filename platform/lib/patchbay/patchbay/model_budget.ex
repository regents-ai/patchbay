defmodule Patchbay.Patchbay.ModelBudget do
  @moduledoc """
  The deployment's ceiling on live model calls.

  Every live call is billed to one server-side key, so the whole deployment may
  make `PATCHBAY_DAILY_MODEL_CALLS` in any rolling 24 hours. Counting reads
  durable evidence, never a counter held in memory: every question Patchbay
  asked a model on OpenRouter (`Patchbay.Assist.ModelCall`), whether it was
  answered or not. A fix already under way finishes its own questions once it
  has started. The readings of posts before they are published are not counted
  here: `Patchbay.Assist.ModelCalls` holds them to a ceiling of their own.
  """

  require Ash.Query

  alias Patchbay.Assist.ModelCall
  alias Patchbay.Config

  @window_seconds 24 * 60 * 60

  @doc "Whether a live model call may start right now."
  @spec allow() :: :ok | {:error, String.t()}
  def allow do
    cap = Config.daily_model_calls()
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    if calls_since(since) < cap do
      :ok
    else
      {:error,
       "Patchbay has used all #{cap} of its model calls for the last 24 hours. Try again later."}
    end
  end

  # A count of the deployment's own questions, read for a limit and shown to no one.
  defp calls_since(since) do
    ModelCall
    |> Ash.Query.filter(inserted_at >= ^since and purpose != :check_post)
    |> Ash.count!(authorize?: false)
  end
end
