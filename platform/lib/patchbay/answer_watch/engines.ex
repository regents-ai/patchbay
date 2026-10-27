defmodule Patchbay.AnswerWatch.Engines do
  @moduledoc """
  Asks one tracked question of one answer engine, with web search on, and
  returns the answer's words, the addresses it cites and the model that
  answered.

  ChatGPT is asked through OpenAI's Responses API with its web search tool;
  Perplexity through OpenRouter's chat completions, which hands back
  Perplexity's sources as URL citations on the message. Where each is and
  which model answers are set in `config :patchbay, :answer_watch`; the keys
  come from `config/runtime.exs`. The request carries a key, so what went
  wrong is reduced to a status or a reason before anything is returned.
  """

  @receive_timeout_ms 120_000

  @type answered :: %{model: String.t(), answer: String.t(), cited_urls: [String.t()]}

  @doc "What `engine` answers to `question`."
  @spec ask(:chatgpt | :perplexity, String.t()) :: {:ok, answered()} | {:error, term()}
  def ask(:chatgpt, question) do
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

  def ask(:perplexity, question) do
    with {:ok, key} <- key(:api_key, Application.fetch_env!(:patchbay, :openrouter)),
         {:ok, body} <-
           post(settings()[:perplexity_url], key, %{
             model: settings()[:perplexity_model],
             messages: [%{role: "user", content: question}]
           }) do
      perplexity_answer(body)
    end
  end

  @doc "Whether any of `urls` is an address on patchbay.help."
  @spec patchbay_cited?([String.t()]) :: boolean()
  def patchbay_cited?(urls) do
    Enum.any?(urls, fn url ->
      host = URI.parse(url).host || ""
      host == "patchbay.help" or String.ends_with?(host, ".patchbay.help")
    end)
  end

  @doc "Whether `answer` names Patchbay."
  @spec patchbay_mentioned?(String.t()) :: boolean()
  def patchbay_mentioned?(answer), do: Regex.match?(~r/\bpatchbay\b/i, answer)

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
