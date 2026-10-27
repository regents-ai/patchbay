defmodule Patchbay.AnswerWatch.Ask do
  @moduledoc """
  Asks one tracked question of one engine for one week and writes the answer
  down (`Patchbay.AnswerWatch.Answer`). An answer already recorded for that
  week is never asked for again, so a retry or a second start pays once. A
  question no longer tracked, or an engine whose key this deployment lacks,
  ends the ask for good; any other failure is tried again.
  """

  use Oban.Worker,
    queue: :answer_watch,
    max_attempts: 3,
    unique: [keys: [:week, :engine, :question], period: :infinity, states: :incomplete]

  require Ash.Query

  alias Patchbay.AnswerWatch
  alias Patchbay.AnswerWatch.{Answer, Engines, Questions}

  @engines %{"chatgpt" => :chatgpt, "perplexity" => :perplexity}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"week" => week, "engine" => engine, "question" => question}}) do
    week = Date.from_iso8601!(week)
    engine = Map.fetch!(@engines, engine)

    case Questions.find(question) do
      nil -> {:cancel, :no_longer_tracked}
      tracked -> if recorded?(week, engine, question), do: :ok, else: ask(week, engine, tracked)
    end
  end

  defp ask(week, engine, tracked) do
    case Engines.ask(engine, tracked.question) do
      {:ok, answered} ->
        tracked
        |> Map.merge(answered)
        |> Map.merge(%{
          week: week,
          engine: engine,
          patchbay_cited: Engines.patchbay_cited?(answered.cited_urls),
          patchbay_mentioned: Engines.patchbay_mentioned?(answered.answer)
        })
        # Patchbay's own record of what the engine answered.
        |> AnswerWatch.record_answer!(authorize?: false)

        :ok

      {:error, :api_key_missing} ->
        {:cancel, :api_key_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recorded?(week, engine, question) do
    Answer
    |> Ash.Query.filter(week == ^week and engine == ^engine and question == ^question)
    # Patchbay's own records.
    |> Ash.exists?(authorize?: false)
  end
end
