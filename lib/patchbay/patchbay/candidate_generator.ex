defmodule Patchbay.Patchbay.CandidateGenerator do
  @moduledoc """
  Produces a bounded Skill candidate for an invocation.

  Live Responses API inference is optional for the demo. A deterministic
  checked-in fallback is available only when explicitly enabled and is always
  labeled in the returned metadata and warning text.
  """

  alias Patchbay.Patchbay.{CanonicalJSON, CandidateCache, Digest, Fixtures, Frontmatter}
  alias Patchbay.Patchbay.OpenAI.Client

  @prompt_version "patchbay-candidate-v1"
  @fallback_warning "Demo fallback used because live inference was unavailable."
  @task_warning "This candidate has not been evaluated on real tasks."

  @spec generate(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(source, arguments, opts \\ [])

  def generate(source, arguments, opts) when is_binary(source) and is_map(arguments) do
    generation_key = Digest.generation_key(Digest.sha256(source), arguments)
    input_sha256 = Digest.sha256(source <> <<0>> <> CanonicalJSON.encode(arguments))

    live_variant =
      cache_variant(
        :live,
        Keyword.get(opts, :model, "gpt-5.6-terra"),
        Keyword.get(opts, :prompt_version, @prompt_version)
      )

    case generate_variant(
           source,
           arguments,
           generation_key,
           input_sha256,
           opts,
           live_variant,
           fn -> live_generate(source, arguments, opts) end
         ) do
      {:ok, generated} ->
        {:ok, generated}

      {:error, live_reason} ->
        if fallback_enabled?(opts) do
          fallback_variant =
            cache_variant(
              :fallback,
              "patchbay-demo-fallback",
              Keyword.get(opts, :prompt_version, @prompt_version)
            )

          generate_variant(
            source,
            arguments,
            generation_key,
            input_sha256,
            opts,
            fallback_variant,
            fn -> {:ok, fallback_result(source, arguments, live_reason)} end
          )
        else
          {:error, {:model_generation_failed, live_reason}}
        end
    end
  rescue
    ArgumentError -> {:error, :invalid_generation_input}
  end

  def generate(_source, _arguments, _opts), do: {:error, :invalid_generation_input}

  @spec generate!(binary(), map(), keyword()) :: map()
  def generate!(source, arguments, opts \\ []) do
    case generate(source, arguments, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "candidate generation failed: #{inspect(reason)}"
    end
  end

  @spec fallback_warning() :: String.t()
  def fallback_warning, do: @fallback_warning

  defp generate_variant(
         source,
         _arguments,
         generation_key,
         input_sha256,
         _opts,
         cache_variant,
         generator
       ) do
    CandidateCache.fetch_or_generate(
      generation_key,
      cache_variant,
      fn ->
        case generator.() do
          {:ok, result} when is_map(result) ->
            result =
              result
              |> Map.put(
                :fallback_used,
                result[:fallback_used] || result["fallback_used"] || false
              )
              |> Map.put(:fallback_reason, result[:fallback_reason] || result["fallback_reason"])

            with {:ok, candidate} <- validate_candidate(source, candidate_from(result)),
                 {:ok, result} <-
                   normalize_result(
                     result,
                     candidate,
                     generation_key,
                     input_sha256,
                     cache_variant
                   ) do
              {:ok, result}
            end

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :generator_result_invalid}
        end
      end,
      fn cached ->
        cached_result_valid?(
          cached,
          source,
          generation_key,
          input_sha256,
          cache_variant
        )
      end
    )
  end

  @doc false
  @spec validate_generated(map(), binary(), map(), keyword()) :: :ok | {:error, term()}
  def validate_generated(generated, source, arguments, _opts \\ [])

  def validate_generated(generated, source, arguments, _opts)
      when is_map(generated) and is_binary(source) and is_map(arguments) do
    generation_key = Digest.generation_key(Digest.sha256(source), arguments)
    input_sha256 = Digest.sha256(source <> <<0>> <> CanonicalJSON.encode(arguments))
    cache_variant = Map.get(generated, :cache_variant) || Map.get(generated, "cache_variant")

    with true <- is_binary(cache_variant),
         true <-
           cached_result_valid?(generated, source, generation_key, input_sha256, cache_variant),
         {:ok, _candidate} <- validate_candidate(source, candidate_from(generated)) do
      :ok
    else
      false -> {:error, :candidate_provenance_invalid}
      {:error, _} = error -> error
    end
  end

  def validate_generated(_generated, _source, _arguments, _opts),
    do: {:error, :candidate_provenance_invalid}

  @doc false
  @spec validate_provenance(map(), binary(), map()) :: :ok | {:error, term()}
  def validate_provenance(generated, source, arguments)
      when is_map(generated) and is_binary(source) and is_map(arguments) do
    generation_key = Digest.generation_key(Digest.sha256(source), arguments)
    input_sha256 = Digest.sha256(source <> <<0>> <> CanonicalJSON.encode(arguments))
    cache_variant = Map.get(generated, :cache_variant) || Map.get(generated, "cache_variant")

    if is_binary(cache_variant) and
         provenance_valid?(generated, generation_key, input_sha256, cache_variant) do
      :ok
    else
      {:error, :candidate_provenance_invalid}
    end
  end

  def validate_provenance(_generated, _source, _arguments),
    do: {:error, :candidate_provenance_invalid}

  defp cached_result_valid?(cached, source, generation_key, input_sha256, cache_variant)
       when is_map(cached) do
    candidate = candidate_from(cached)
    candidate_sha256 = cached[:candidate_sha256] || cached["candidate_sha256"]

    is_binary(candidate) and Digest.sha256(candidate) == candidate_sha256 and
      provenance_valid?(cached, generation_key, input_sha256, cache_variant) and
      match?({:ok, _}, validate_candidate(source, candidate))
  end

  defp cached_result_valid?(_cached, _source, _generation_key, _input_sha256, _cache_variant),
    do: false

  defp provenance_valid?(cached, generation_key, input_sha256, cache_variant)
       when is_map(cached) do
    candidate = candidate_from(cached)
    candidate_sha256 = cached[:candidate_sha256] || cached["candidate_sha256"]
    cached_generation_key = cached[:generation_key] || cached["generation_key"]
    cached_input_sha256 = cached[:input_sha256] || cached["input_sha256"]
    cached_variant = cached[:cache_variant] || cached["cache_variant"]

    is_binary(candidate) and Digest.sha256(candidate) == candidate_sha256 and
      cached_generation_key == generation_key and cached_input_sha256 == input_sha256 and
      cached_variant == cache_variant
  end

  defp provenance_valid?(_cached, _generation_key, _input_sha256, _cache_variant), do: false

  defp cache_variant(mode, model, prompt_version) do
    Digest.sha256(
      CanonicalJSON.encode(%{
        "mode" => mode,
        "model" => model,
        "prompt_version" => prompt_version
      })
    )
  end

  defp live_generate(source, arguments, opts) do
    cond do
      is_function(opts[:generator], 2) ->
        normalize_generator_result(opts[:generator].(source, arguments))

      is_function(opts[:generator], 3) ->
        normalize_generator_result(opts[:generator].(source, arguments, opts))

      is_function(opts[:request], 3) ->
        Client.generate_candidate(source, arguments, Keyword.put(opts, :request, opts[:request]))

      api_key_available?(opts) ->
        Client.generate_candidate(source, arguments, opts)

      true ->
        {:error, :api_key_missing}
    end
  end

  defp normalize_generator_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_generator_result(result) when is_map(result), do: {:ok, result}
  defp normalize_generator_result({:error, reason}), do: {:error, reason}
  defp normalize_generator_result(_), do: {:error, :generator_result_invalid}

  defp fallback_result(source, arguments, reason) do
    candidate = fallback_candidate(source)

    %{
      candidate_markdown: candidate,
      change_summary: ["Applied the checked-in Patchbay demo improvement."],
      warnings: [@fallback_warning, @task_warning],
      model: "patchbay-demo-fallback",
      model_response_id: "demo-fallback-#{Digest.sha256(inspect(reason))}",
      prompt_version: @prompt_version,
      fallback_used: true,
      fallback_reason: reason,
      instructions: arguments
    }
  end

  defp fallback_candidate(source) do
    if source == Fixtures.source_markdown() do
      Fixtures.improved_markdown()
    else
      case Frontmatter.extract(source) do
        {:ok, _metadata, body} ->
          source <>
            "\n\n## Clarified guidance\n\n" <>
            "The candidate keeps the source identity and makes the requested workflow explicit.\n" <>
            String.trim(body)

        _ ->
          source <> "\n\n## Clarified guidance\n"
      end
    end
  end

  defp validate_candidate(source, candidate) when is_binary(candidate) do
    cond do
      not String.valid?(candidate) ->
        {:error, :candidate_invalid_utf8}

      Digest.validate_artifact(candidate) != :ok ->
        {:error, :candidate_too_large}

      String.contains?(candidate, <<0>>) ->
        {:error, :candidate_contains_nul}

      String.to_charlist(candidate) |> Enum.any?(&(&1 in 0xE0000..0xE007F)) ->
        {:error, :candidate_contains_hidden_unicode}

      not Frontmatter.valid?(candidate) ->
        {:error, :candidate_frontmatter_invalid}

      not Patchbay.Patchbay.PostconditionVerifier.identity_preserved?(source, candidate) ->
        {:error, :candidate_identity_not_preserved}

      candidate == source ->
        {:error, :candidate_unchanged}

      true ->
        {:ok, candidate}
    end
  end

  defp validate_candidate(_source, _candidate), do: {:error, :candidate_must_be_string}

  defp normalize_result(result, candidate, generation_key, input_sha256, cache_variant) do
    change_summary =
      normalize_bounded_list(result[:change_summary] || result["change_summary"], 6, 240)

    warnings = normalize_bounded_list(result[:warnings] || result["warnings"], 4, 240)

    if is_nil(change_summary) or is_nil(warnings) do
      {:error, :candidate_metadata_invalid}
    else
      {:ok,
       %{
         candidate_markdown: candidate,
         candidate_sha256: Digest.sha256(candidate),
         generation_key: generation_key,
         input_sha256: input_sha256,
         cache_variant: cache_variant,
         change_summary: change_summary,
         warnings: Enum.take(Enum.uniq(warnings), 3) ++ [@task_warning],
         model: result[:model] || result["model"] || "unknown-model",
         model_response_id:
           result[:model_response_id] || result["model_response_id"] || "unknown-response",
         prompt_version: result[:prompt_version] || result["prompt_version"] || @prompt_version,
         fallback_used: result[:fallback_used] || result["fallback_used"] || false,
         fallback_reason: result[:fallback_reason] || result["fallback_reason"]
       }}
    end
  end

  defp normalize_bounded_list(value, max_items, max_bytes) when is_list(value) do
    if length(value) <= max_items and
         Enum.all?(
           value,
           &(is_binary(&1) and byte_size(&1) <= max_bytes and String.trim(&1) != "")
         ) do
      value
    end
  end

  defp normalize_bounded_list(_, _max_items, _max_bytes), do: nil

  defp candidate_from(result) do
    result[:candidate_markdown] || result["candidate_markdown"] ||
      result[:improved_skill_markdown] || result["improved_skill_markdown"]
  end

  defp fallback_enabled?(opts) do
    Keyword.get(opts, :fallback, false) or
      Application.get_env(:patchbay, :demo_fallback, false) or
      System.get_env("PATCHBAY_DEMO_FALLBACK") in ["true", "1"]
  end

  defp api_key_available?(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")
    is_binary(key) and key != ""
  end
end
