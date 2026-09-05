defmodule Patchbay.Patchbay.OpenAI.Client do
  @moduledoc """
  Minimal server-side Responses API client.

  It sends structured output requests with no tools enabled and never logs the
  source Skill or model output. Tests may inject a `:request` function.
  """

  alias Patchbay.Patchbay.OpenAI.{CandidateSchema, Prompts, RepairSchema}

  @endpoint "https://api.openai.com/v1/responses"
  @model "gpt-5.6-terra"
  @reasoning %{effort: "low"}
  @usage_keys ["input_tokens", "output_tokens", "total_tokens"]

  @spec generate_candidate(binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate_candidate(source, arguments, opts \\ []) do
    respond(
      %{
        system: Prompts.candidate_system(),
        user: Prompts.candidate_user(inspect_argument(arguments), source),
        schema_name: "patchbay_candidate",
        schema: CandidateSchema.schema(),
        receive_timeout: 20_000,
        prompt_version: "patchbay-candidate-v1",
        result: &candidate_result/1
      },
      opts
    )
  end

  @spec repair_plan(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def repair_plan(input, opts \\ []) when is_map(input) do
    respond(
      %{
        system: Prompts.repair_system(),
        user: Jason.encode!(input),
        schema_name: "patchbay_repair",
        schema: RepairSchema.schema(),
        receive_timeout: 12_000,
        prompt_version: "patchbay-repair-v1",
        result: &repair_result/1
      },
      opts
    )
  end

  # Every call is the same envelope, sent the same way, and answered with the
  # same provenance. Only the schema the model is held to and the fields read
  # back out of its output differ, and both of those arrive with the request.
  defp respond(parts, opts) do
    request = Keyword.get(opts, :request, &request/3)
    model = Keyword.get(opts, :model, @model)
    prompt_version = Keyword.get(opts, :prompt_version, parts.prompt_version)

    with {:ok, response} <-
           request.(
             payload(parts, model),
             Keyword.put_new(opts, :receive_timeout, parts.receive_timeout),
             @endpoint
           ),
         {:ok, output} <- extract_output(response),
         {:ok, result} <- parts.result.(output) do
      {:ok,
       Map.merge(result, %{
         model: model,
         model_response_id: response_id(response),
         prompt_version: prompt_version,
         usage: usage(response)
       })}
    end
  end

  defp payload(parts, model) do
    %{
      model: model,
      tools: [],
      reasoning: @reasoning,
      input: [
        %{role: "system", content: [%{type: "input_text", text: parts.system}]},
        %{role: "user", content: [%{type: "input_text", text: parts.user}]}
      ],
      text: %{
        format: %{
          type: "json_schema",
          name: parts.schema_name,
          strict: true,
          schema: parts.schema
        }
      }
    }
  end

  defp candidate_result(output) do
    with :ok <- validate_shape(output) do
      {:ok,
       %{
         candidate_markdown: output["improved_skill_markdown"],
         change_summary: output["change_summary"],
         warnings: output["warnings"]
       }}
    end
  end

  defp repair_result(output), do: {:ok, %{plan: output}}

  defp request(payload, opts, endpoint) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    if is_binary(api_key) and api_key != "" do
      receive_timeout = Keyword.get(opts, :receive_timeout, 20_000)

      case Req.post(endpoint,
             json: payload,
             headers: [{"authorization", "Bearer " <> api_key}],
             receive_timeout: receive_timeout,
             request_timeout: receive_timeout,
             connect_options: [timeout: min(receive_timeout, 5_000)],
             retry: false
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :api_key_missing}
    end
  rescue
    error -> {:error, {:request_failed, Exception.message(error)}}
  end

  defp extract_output(%{"output_text" => output}) when is_binary(output) do
    decode_output(output)
  end

  defp extract_output(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&content_text/1)
    |> Enum.join()
    |> decode_output()
  end

  defp extract_output(_), do: {:error, :response_output_missing}

  defp content_text(item) do
    item
    |> Map.get("content", [])
    |> Enum.flat_map(fn
      %{"text" => value} when is_binary(value) -> [value]
      _ -> []
    end)
  end

  defp decode_output(value) do
    case Jason.decode(value) do
      {:ok, output} when is_map(output) -> {:ok, output}
      _ -> {:error, :response_output_invalid}
    end
  end

  defp validate_shape(output) do
    with true <- is_binary(output["improved_skill_markdown"]),
         true <- is_list(output["change_summary"]),
         true <- is_list(output["warnings"]) do
      :ok
    else
      _ -> {:error, :response_shape_invalid}
    end
  end

  defp response_id(%{"id" => id}) when is_binary(id), do: id
  defp response_id(_), do: "unknown-response"

  defp usage(%{"usage" => usage}), do: normalize_usage(usage)
  defp usage(_), do: %{}

  @doc """
  Keeps only the bounded token counters Patchbay records. Anything else the
  provider returns is dropped so no free-form response text can reach storage.
  """
  @spec normalize_usage(term()) :: %{optional(binary()) => non_neg_integer()}
  def normalize_usage(usage) when is_map(usage) do
    Enum.reduce(@usage_keys, %{}, fn key, acc ->
      case Map.get(usage, key) do
        count when is_integer(count) and count >= 0 -> Map.put(acc, key, count)
        _unusable -> acc
      end
    end)
  end

  def normalize_usage(_), do: %{}

  defp inspect_argument(arguments) do
    arguments
    |> Map.get("instructions", "")
    |> to_string()
    |> String.slice(0, 1_000)
  end
end
