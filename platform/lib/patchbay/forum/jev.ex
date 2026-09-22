defmodule Patchbay.Forum.Jev do
  @moduledoc """
  Asks Jev what it makes of one paid priority report.

  Jev is TypeSafe's classifier on OpenRouter. It is not a chat model: it
  answers typed questions about a `state` through the Decisions endpoint, and
  it never writes prose. The questions here are fixed, the state is only what
  the thread already shows the public, and the sentence on the thread is
  written by `PatchbayWeb.Forum.BoardHTML` from the answers.
  """

  alias Patchbay.Forum.JevReading
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.Types.JevKind

  @endpoint "https://openrouter.ai/api/alpha/decisions"
  @model "~typesafe/jev-latest"
  @receive_timeout_ms 60_000

  @kinds %{
    "tool_defect" =>
      "The site's tool misbehaved: a wrong, empty or failed result for a valid call.",
    "usage_question" => "The caller needs to know how to call the tool or what it expects.",
    "setup_problem" =>
      "The caller's browser, host or permissions kept the tool from being reached at all.",
    "other" => "None of the above."
  }

  @type answers :: %{
          model: String.t(),
          kind: atom(),
          kind_confidence: float(),
          detail_score: float()
        }

  @doc "Whether this deployment holds the key Jev is asked with."
  @spec configured?() :: boolean()
  def configured?, do: api_key() not in [nil, ""]

  @doc "One Decisions call about `report`. `report` needs `:site` and `:tool` loaded."
  @spec read(Report.t()) :: {:ok, answers()} | {:error, term()}
  def read(%Report{} = report) do
    with {:ok, body} <- decide(state(report), questions()) do
      answers(body)
    end
  end

  @doc """
  One Decisions call: Jev's answers to `questions` about `state`, as the
  provider returned them. The caller reads the answers it asked for; `state`
  must already be only what may leave Patchbay.
  """
  @spec decide(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(state, questions, opts \\ []) do
    case api_key() do
      key when key in [nil, ""] -> {:error, :api_key_missing}
      key -> ask(state, questions, key, opts)
    end
  end

  defp ask(state, questions, key, opts) do
    options =
      [
        json: %{model: @model, state: state, questions: questions},
        headers: [
          {"authorization", "Bearer " <> key},
          {"http-referer", PatchbayWeb.Endpoint.url()},
          {"x-title", "Patchbay"}
        ],
        receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout_ms),
        retry: false
      ] ++ Application.get_env(:patchbay, :jev_req_options, [])

    # The request carries the key, so what went wrong is reduced to a status
    # or a reason before anything is returned or logged.
    case Req.post(@endpoint, options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, :unexpected_answers}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, _other} -> {:error, :request_failed}
    end
  end

  # Only what the thread already shows the public.
  defp state(report) do
    %{
      site: report.site.origin,
      tool: report.tool.name,
      verdict: report.verdict,
      failure_code: report.failure_code,
      note: report.note,
      tool_returned: report.handler_result,
      seen_on_page: report.observed
    }
  end

  defp questions do
    %{
      kind: %{
        type: "choice",
        instructions: "What kind of help is this report of a website tool call asking for?",
        criteria: @kinds
      },
      detail: %{
        type: "score",
        instructions: "How complete are the steps another agent would need to reproduce this?",
        criteria: JevReading.detail_labels()
      }
    }
  end

  defp answers(%{
         "model" => model,
         "answers" => %{
           "kind" => %{"choice" => kind, "confidence" => confidence},
           "detail" => %{"score" => score}
         }
       })
       when is_binary(model) and is_map_key(@kinds, kind) and is_number(confidence) and
              is_number(score) do
    {:ok, kind} = JevKind.cast_input(kind, [])
    {:ok, %{model: model, kind: kind, kind_confidence: confidence / 1, detail_score: score / 1}}
  end

  defp answers(_body), do: {:error, :unexpected_answers}

  defp api_key, do: System.get_env("OPENROUTER_API_KEY")
end
