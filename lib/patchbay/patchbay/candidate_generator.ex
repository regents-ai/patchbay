defmodule Patchbay.Patchbay.CandidateGenerator do
  @moduledoc """
  Produces a bounded Skill candidate for an invocation.

  Live Responses API inference is optional for the demo. A deterministic
  checked-in fallback is available only when explicitly enabled and is always
  labeled in the returned metadata and warning text.

  A live call is asked for only after the cache misses, so a repeat of the same
  request is served without spending anything and without consulting the spend
  limits in `Patchbay.Patchbay.ModelBudget`. Pass `:room_id` so those limits can
  pace the room the call belongs to.

  This module also owns the candidate cache, so a candidate is only ever built
  or rebuilt here.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Config

  alias Patchbay.Patchbay.{
    CandidateCache,
    CanonicalJSON,
    Digest,
    Fixtures,
    Frontmatter,
    Invocation,
    ModelBudget,
    PostconditionVerifier
  }

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
           generation_key,
           input_sha256,
           live_variant,
           fn -> budgeted_live_generate(source, arguments, opts) end
         ) do
      {:ok, generated} ->
        {:ok, generated}

      {:error, live_reason} ->
        demo_candidate(source, generation_key, input_sha256, live_reason, opts)
    end
  rescue
    ArgumentError -> {:error, :invalid_generation_input}
  end

  def generate(_source, _arguments, _opts), do: {:error, :invalid_generation_input}

  # When live inference is unavailable the demo still needs something to show,
  # so it produces the canned candidate under its own cache variant. Outside the
  # demo the call simply fails.
  defp demo_candidate(source, generation_key, input_sha256, live_reason, opts) do
    if fallback_enabled?(opts) do
      generate_variant(
        source,
        generation_key,
        input_sha256,
        cache_variant(
          :fallback,
          "patchbay-demo-fallback",
          Keyword.get(opts, :prompt_version, @prompt_version)
        ),
        fn -> {:ok, fallback_result(source, live_reason)} end
      )
    else
      {:error, {:model_generation_failed, live_reason}}
    end
  end

  @spec generate!(binary(), map(), keyword()) :: map()
  def generate!(source, arguments, opts \\ []) do
    case generate(source, arguments, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "candidate generation failed: #{inspect(reason)}"
    end
  end

  @doc """
  Rebuilds the candidate a recorded call produced, from the call itself.

  A retry and a repair both need the candidate a failed call generated, and the
  invocation row is the only durable record of it, so both come here rather
  than each reassembling it. What comes back is proved to belong to the room's
  current source and arguments; whether its text is still a usable Skill is a
  separate question, answered by the rerun's own validation or by the canary.
  """
  @spec durable_candidate!(Invocation.t(), binary()) :: map()
  def durable_candidate!(invocation, source) do
    generated = rebuild_candidate(invocation)

    case validate_provenance(generated, source, invocation.arguments) do
      :ok ->
        generated

      {:error, reason} ->
        raise Ash.Error.to_error_class(
                InvalidAttribute.exception(
                  field: :generated_candidate,
                  message: "durable candidate evidence is invalid: #{inspect(reason)}"
                )
              )
    end
  end

  # The handler result is free-form JSON from the tool call, so it is read with
  # the string keys PostgreSQL gives back and turned into a candidate here.
  defp rebuild_candidate(invocation) do
    handler_result = invocation.handler_result || %{}
    provenance = Map.get(handler_result, "candidate_provenance") || %{}

    %{
      candidate_markdown: invocation.generated_candidate,
      candidate_sha256: invocation.generated_candidate_sha256,
      generation_key: invocation.generation_key,
      input_sha256: provenance["input_sha256"],
      cache_variant: provenance["cache_variant"],
      change_summary: handler_result["change_summary"] || [],
      warnings: handler_result["warnings"] || [],
      model: provenance["model"],
      model_response_id: provenance["model_response_id"],
      prompt_version: provenance["prompt_version"],
      fallback_used: provenance["fallback_used"],
      fallback_reason: provenance["fallback_reason"],
      usage: Client.normalize_usage(provenance["usage"])
    }
  end

  @spec fallback_warning() :: String.t()
  def fallback_warning, do: @fallback_warning

  @doc """
  Classifies the characters Patchbay refuses in Skill text.

  A NUL byte cannot be stored and the Unicode tag range (U+E0000..U+E007F) is
  invisible on screen, so text carrying either is refused whether it arrives
  from a person or comes back from a model. Callers check `String.valid?/1`
  first.
  """
  @spec unsupported_characters(binary()) :: :nul | :hidden_unicode | nil
  def unsupported_characters(text) when is_binary(text) do
    cond do
      String.contains?(text, <<0>>) -> :nul
      String.match?(text, ~r/[\x{E0000}-\x{E007F}]/u) -> :hidden_unicode
      true -> nil
    end
  end

  defp generate_variant(
         source,
         generation_key,
         input_sha256,
         cache_variant,
         generator
       ) do
    CandidateCache.fetch_or_generate(
      generation_key,
      cache_variant,
      fn -> generated_result(generator, source, generation_key, input_sha256, cache_variant) end,
      fn cached ->
        cached_result_valid?(cached, source, generation_key, input_sha256, cache_variant)
      end
    )
  end

  defp generated_result(generator, source, generation_key, input_sha256, cache_variant) do
    case generator.() do
      {:ok, result} when is_map(result) ->
        with {:ok, candidate} <- validate_candidate(source, result[:candidate_markdown]) do
          normalize_result(result, candidate, generation_key, input_sha256, cache_variant)
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :generator_result_invalid}
    end
  end

  @doc false
  @spec validate_generated(map(), binary(), map()) :: :ok | {:error, term()}
  def validate_generated(generated, source, arguments)
      when is_map(generated) and is_binary(source) and is_map(arguments) do
    generation_key = Digest.generation_key(Digest.sha256(source), arguments)
    input_sha256 = Digest.sha256(source <> <<0>> <> CanonicalJSON.encode(arguments))

    with true <- is_binary(generated[:cache_variant]),
         true <-
           cached_result_valid?(
             generated,
             source,
             generation_key,
             input_sha256,
             generated.cache_variant
           ) do
      :ok
    else
      false -> {:error, :candidate_provenance_invalid}
    end
  end

  def validate_generated(_generated, _source, _arguments),
    do: {:error, :candidate_provenance_invalid}

  @doc false
  @spec validate_provenance(map(), binary(), map()) :: :ok | {:error, term()}
  def validate_provenance(generated, source, arguments)
      when is_map(generated) and is_binary(source) and is_map(arguments) do
    generation_key = Digest.generation_key(Digest.sha256(source), arguments)
    input_sha256 = Digest.sha256(source <> <<0>> <> CanonicalJSON.encode(arguments))

    if is_binary(generated[:cache_variant]) and
         provenance_valid?(generated, generation_key, input_sha256, generated.cache_variant) do
      :ok
    else
      {:error, :candidate_provenance_invalid}
    end
  end

  def validate_provenance(_generated, _source, _arguments),
    do: {:error, :candidate_provenance_invalid}

  defp cached_result_valid?(cached, source, generation_key, input_sha256, cache_variant)
       when is_map(cached) do
    provenance_valid?(cached, generation_key, input_sha256, cache_variant) and
      match?({:ok, _}, validate_candidate(source, cached[:candidate_markdown]))
  end

  defp cached_result_valid?(_cached, _source, _generation_key, _input_sha256, _cache_variant),
    do: false

  defp provenance_valid?(cached, generation_key, input_sha256, cache_variant)
       when is_map(cached) do
    candidate = cached[:candidate_markdown]

    is_binary(candidate) and Digest.sha256(candidate) == cached[:candidate_sha256] and
      cached[:generation_key] == generation_key and cached[:input_sha256] == input_sha256 and
      cached[:cache_variant] == cache_variant
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

  defp budgeted_live_generate(source, arguments, opts) do
    with :ok <- ModelBudget.allow(Keyword.get(opts, :room_id), :candidate) do
      live_generate(source, arguments, opts)
    end
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

  defp fallback_result(source, reason) do
    candidate = fallback_candidate(source)

    %{
      candidate_markdown: candidate,
      change_summary: ["Applied the checked-in Patchbay demo improvement."],
      warnings: [@fallback_warning, @task_warning],
      model: "patchbay-demo-fallback",
      model_response_id: "demo-fallback-#{Digest.sha256(inspect(reason))}",
      prompt_version: @prompt_version,
      fallback_used: true,
      fallback_reason: reason
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

      true ->
        validate_skill_text(source, candidate, unsupported_characters(candidate))
    end
  end

  defp validate_candidate(_source, _candidate), do: {:error, :candidate_must_be_string}

  defp validate_skill_text(_source, _candidate, :nul), do: {:error, :candidate_contains_nul}

  defp validate_skill_text(_source, _candidate, :hidden_unicode),
    do: {:error, :candidate_contains_hidden_unicode}

  defp validate_skill_text(source, candidate, nil) do
    cond do
      not Frontmatter.valid?(candidate) ->
        {:error, :candidate_frontmatter_invalid}

      not PostconditionVerifier.identity_preserved?(source, candidate) ->
        {:error, :candidate_identity_not_preserved}

      candidate == source ->
        {:error, :candidate_unchanged}

      true ->
        {:ok, candidate}
    end
  end

  defp normalize_result(result, candidate, generation_key, input_sha256, cache_variant) do
    change_summary = normalize_bounded_list(result[:change_summary], 6, 240)
    warnings = normalize_bounded_list(result[:warnings], 4, 240)

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
         warnings: Enum.take(Enum.uniq(warnings ++ [@task_warning]), 4),
         model: result[:model] || "unknown-model",
         model_response_id: result[:model_response_id] || "unknown-response",
         prompt_version: result[:prompt_version] || @prompt_version,
         fallback_used: result[:fallback_used] || false,
         fallback_reason: result[:fallback_reason],
         usage: Client.normalize_usage(result[:usage])
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

  defp fallback_enabled?(opts) do
    Keyword.get(opts, :fallback, false) or Config.demo_fallback?()
  end

  defp api_key_available?(opts) do
    case Keyword.get(opts, :api_key) do
      nil -> Config.live_inference_configured?()
      key -> is_binary(key) and key != ""
    end
  end
end
