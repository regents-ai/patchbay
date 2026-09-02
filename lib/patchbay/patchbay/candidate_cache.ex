defmodule Patchbay.Patchbay.CandidateCache do
  @moduledoc """
  A small process-local cache for generated candidates.

  The durable invocation row is the source of truth. Cache entries are only a
  performance hint and are partitioned by both the logical generation key and
  the requested inference provenance (provider, model, and prompt version).
  """

  alias Patchbay.Patchbay.Digest

  @table __MODULE__

  @type variant :: String.t()

  @spec get(term(), keyword()) ::
          {:ok, map()} | {:error, :generation_key_required | :not_found | :ambiguous | :invalid}
  def get(key, opts \\ [])

  def get(key, opts) when is_binary(key) and key != "" do
    case Keyword.get(opts, :variant) do
      nil -> get_unqualified(key)
      variant when is_binary(variant) and variant != "" -> get_variant(key, variant)
      _ -> {:error, :invalid}
    end
  end

  def get(_key, _opts), do: {:error, :generation_key_required}

  @spec put(term(), map(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ [])

  def put(key, value, opts) when is_binary(key) and key != "" and is_map(value) do
    variant = Keyword.get(opts, :variant) || Map.get(value, :cache_variant)

    with :ok <- validate_entry(key, value, variant) do
      true = :ets.insert(table(), {entry_key(key, variant), value})
      :ok
    end
  end

  def put(_key, _value, _opts), do: {:error, :generation_key_required}

  @doc "Atomically gets or generates one provenance-qualified cache entry."
  @spec fetch_or_generate(String.t(), variant(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def fetch_or_generate(key, variant, generator)
      when is_binary(key) and key != "" and is_binary(variant) and variant != "" and
             is_function(generator, 0) do
    fetch_or_generate(key, variant, generator, fn _value -> true end)
  end

  @spec fetch_or_generate(
          String.t(),
          variant(),
          (-> {:ok, map()} | {:error, term()}),
          (map() -> boolean())
        ) :: {:ok, map()} | {:error, term()}
  def fetch_or_generate(key, variant, generator, validator)
      when is_binary(key) and key != "" and is_binary(variant) and variant != "" and
             is_function(generator, 0) and is_function(validator, 1) do
    :global.trans({__MODULE__, {key, variant}}, fn ->
      case get(key, variant: variant) do
        {:ok, value} ->
          if validator.(value) do
            {:ok, value}
          else
            delete(key, variant: variant)
            generate_and_store(key, variant, generator)
          end

        {:error, reason} when reason in [:not_found, :invalid] ->
          generate_and_store(key, variant, generator)

        error ->
          error
      end
    end)
  end

  def fetch_or_generate(_key, _variant, _generator, _validator),
    do: {:error, :generation_key_required}

  @spec delete(term(), keyword()) :: :ok
  def delete(key, opts \\ []) do
    if is_binary(key) and key != "" do
      :ets.delete(table(), entry_key(key, Keyword.get(opts, :variant)))
    end

    :ok
  end

  defp generate_and_store(key, variant, generator) do
    case generator.() do
      {:ok, value} ->
        with :ok <- put(key, value, variant: variant), do: get(key, variant: variant)

      {:error, _} = error ->
        error

      value when is_map(value) ->
        with :ok <- put(key, value, variant: variant), do: get(key, variant: variant)

      _ ->
        {:error, :cache_generator_invalid}
    end
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(table())
    :ok
  end

  defp get_unqualified(key) do
    case :ets.lookup(table(), key) do
      [{^key, value}] ->
        if valid_cache_value?(key, value), do: {:ok, value}, else: {:error, :invalid}

      [] ->
        variants =
          :ets.match_object(table(), {{key, :_}, :_})
          |> Enum.map(fn {{^key, _variant}, value} -> value end)
          |> Enum.filter(&valid_cache_value?(key, &1))

        case variants do
          [value] -> {:ok, value}
          [] -> {:error, :not_found}
          _ -> {:error, :ambiguous}
        end
    end
  end

  defp get_variant(key, variant) do
    case :ets.lookup(table(), entry_key(key, variant)) do
      [{_, value}] ->
        if valid_cache_value?(key, value) and Map.get(value, :cache_variant) == variant do
          {:ok, value}
        else
          :ets.delete(table(), entry_key(key, variant))
          {:error, :invalid}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp entry_key(key, nil), do: key
  defp entry_key(key, variant), do: {key, variant}

  defp validate_entry(key, value, variant) do
    cond do
      not valid_cache_value?(key, value) -> {:error, :invalid}
      is_nil(variant) -> :ok
      not is_binary(variant) or variant == "" -> {:error, :invalid}
      Map.get(value, :cache_variant) != variant -> {:error, :invalid}
      true -> :ok
    end
  end

  defp valid_cache_value?(key, value) when is_map(value) do
    candidate = Map.get(value, :candidate_markdown) || Map.get(value, "candidate_markdown")

    generation_key = Map.get(value, :generation_key) || Map.get(value, "generation_key")

    candidate_sha256 =
      Map.get(value, :candidate_sha256) || Map.get(value, "candidate_sha256")

    is_binary(candidate) and is_binary(candidate_sha256) and
      Digest.sha256(candidate) == candidate_sha256 and generation_key == key
  end

  defp valid_cache_value?(_key, _value), do: false

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _tid ->
        @table
    end
  end
end
