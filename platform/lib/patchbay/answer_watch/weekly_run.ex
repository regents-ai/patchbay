defmodule Patchbay.AnswerWatch.WeeklyRun do
  @moduledoc """
  Starts the week's answer check, every Monday at 06:00 UTC: one
  `Patchbay.AnswerWatch.Ask` for each tracked question and each engine.
  Starting it twice in a week asks nothing twice: each ask is unique while it
  waits, and an ask whose answer is already recorded ends without asking.
  """

  use Oban.Worker, queue: :answer_watch, max_attempts: 3

  alias Patchbay.AnswerWatch.{Ask, Questions}

  @engines ["chatgpt", "perplexity"]

  @impl Oban.Worker
  def perform(_job) do
    week = Date.utc_today() |> Date.beginning_of_week() |> Date.to_iso8601()

    for %{question: question} <- Questions.all(), engine <- @engines do
      Oban.insert!(Ask.new(%{week: week, engine: engine, question: question}))
    end

    :ok
  end
end
