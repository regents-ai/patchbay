defmodule Patchbay.AnswerWatch.Ask do
  @moduledoc """
  The weekly answer check's one job, in two shapes.

  Every Monday at 06:00 UTC the schedule starts it with no arguments, and it
  queues one ask for each tracked question (`Patchbay.AnswerWatch.Questions`)
  and each engine. Each ask puts one question to one engine, with web search
  on, and writes the answer down (`Patchbay.AnswerWatch.Answer`) with the
  addresses it cites and whether it links or names Patchbay.

  Starting the week twice asks nothing twice: an ask is unique while it
  waits, and an answer already recorded for that week is never asked for
  again, so a retry or a second start pays once. A question no longer
  tracked, or an engine whose key this deployment lacks, ends the ask for
  good; any other failure is tried again.

  ChatGPT is asked through OpenAI's Responses API with its web search tool;
  Perplexity through OpenRouter's chat completions, which hands back
  Perplexity's sources as URL citations on the message. Where each is and
  which model answers are set in `config :patchbay, :answer_watch`; the keys
  come from `config/runtime.exs`. The request carries a key, so what went
  wrong is reduced to a status or a reason before anything is returned.
  """

  use Oban.Worker, queue: :answer_watch, max_attempts: 3

  require Ash.Query

  alias Patchbay.AnswerWatch
  alias Patchbay.AnswerWatch.{Answer, Questions}

  @engines %{"chatgpt" => :chatgpt, "perplexity" => :perplexity}
  @receive_timeout_ms 120_000
  # Each ask, not the week's start, is one of a kind while it waits.
  @unique [keys: [:week, :engine, :question], period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"week" => week, "engine" => engine, "question" => question}}) do
    week = Date.from_iso8601!(week)
    engine = Map.fetch!(@engines, engine)

    case Questions.find(question) do
      nil -> {:cancel, :no_longer_tracked}
      tracked -> if recorded?(week, engine, question), do: :ok, else: ask(week, engine, tracked)
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    week = Date.utc_today() |> Date.beginning_of_week() |> Date.to_iso8601()

    for %{question: question} <- Questions.all(), engine <- Map.keys(@engines) do
      Oban.insert!(new(%{week: week, engine: engine, question: question}, unique: @unique))
    end

    :ok
  end

  defp ask(week, engine, tracked) do
    case answer(engine, tracked.question) do
      {:ok, answered} ->
        tracked
        |> Map.merge(answered)
        |> Map.merge(%{
          week: week,
          engine: engine,
          patchbay_cited: Enum.any?(answered.cited_urls, &patchbay_address?/1),
          patchbay_mentioned: Regex.match?(~r/\bpatchbay\b/i, answered.answer)
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

  defp patchbay_address?(url) do
    host = URI.parse(url).host || ""
    host == "patchbay.help" or String.ends_with?(host, ".patchbay.help")
  end

  # The answer's words, the addresses it cites and the model that answered.
  defp answer(:chatgpt, question) do
    with {:ok, key} <- key(:openai_api_key, settings()),
         {:ok, body} <-
           post(settings()[:chatgpt_url], key, %{
             model: settings()[:chatgpt_model],
             input: question,
             tools: [%{type: "web_search"}]
           }) do
      chatgpt_answer(body)
    end
  end

  defp answer(:perplexity, question) do
    with {:ok, key} <- key(:api_key, Application.fetch_env!(:patchbay, :openrouter)),
         {:ok, body} <-
           post(settings()[:perplexity_url], key, %{
             model: settings()[:perplexity_model],
             messages: [%{role: "user", content: question}]
           }) do
      perplexity_answer(body)
    end
  end

  # The answer is the text of every message the model wrote; its sources are
  # the URL citations on that text.
  defp chatgpt_answer(%{"model" => model, "output" => output}) when is_list(output) do
    texts =
      for %{"type" => "message", "content" => content} <- output,
          %{"type" => "output_text"} = text <- content,
          do: text

    case texts do
      [] ->
        {:error, :unexpected_answer}

      texts ->
        {:ok,
         %{
           model: model,
           answer: Enum.map_join(texts, "\n\n", & &1["text"]),
           cited_urls: texts |> Enum.flat_map(&(&1["annotations"] || [])) |> urls()
         }}
    end
  end

  defp chatgpt_answer(_body), do: {:error, :unexpected_answer}

  defp perplexity_answer(%{
         "model" => model,
         "choices" => [%{"message" => %{"content" => answer} = message} | _]
       })
       when is_binary(answer) do
    cited = for %{"url_citation" => citation} <- message["annotations"] || [], do: citation
    {:ok, %{model: model, answer: answer, cited_urls: urls(cited)}}
  end

  defp perplexity_answer(_body), do: {:error, :unexpected_answer}

  defp urls(citations) do
    citations
    |> Enum.flat_map(fn
      %{"url" => url} when is_binary(url) -> [url]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp post(url, key, payload) do
    options =
      [
        json: payload,
        headers: [{"authorization", "Bearer " <> key}],
        receive_timeout: @receive_timeout_ms,
        retry: false
      ] ++ Application.get_env(:patchbay, :answer_watch_req_options, [])

    case RegentHttp.post(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, :unexpected_answer}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, _other} -> {:error, :request_failed}
    end
  end

  defp key(name, settings) do
    case Keyword.get(settings, name) do
      key when key in [nil, ""] -> {:error, :api_key_missing}
      key -> {:ok, key}
    end
  end

  defp settings, do: Application.fetch_env!(:patchbay, :answer_watch)
end
