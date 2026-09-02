defmodule Patchbay.Patchbay.CandidateCache do
  @moduledoc """
  A small process-local cache for generated candidates.

  The durable invocation row is the source of truth. Cache entries are only a
  performance hint and are always partitioned by both the logical generation key
  and the requested inference provenance (provider, model, and prompt version),
  so a candidate produced one way can never be served for a request that asked
  for another.
  """

  alias Patchbay.Patchbay.Digest

  @table __MODULE__

  @type variant :: String.t()

  @spec get(term(), keyword()) ::
          {:ok, map()} | {:error, :generation_key_required | :not_found | :invalid}
  def get(key, opts \\ [])

  def get(key, opts) when is_binary(key) and key != "" do
    case Keyword.get(opts, :variant) do
      variant when is_binary(variant) and variant != "" -> get_variant(key, variant)
      _missing -> {:error, :invalid}
    end
  end

  def get(_key, _opts), do: {:error, :generation_key_required}

  @spec put(term(), map(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ [])

  def put(key, value, opts) when is_binary(key) and key != "" and is_map(value) do
    variant = Keyword.get(opts, :variant) || value[:cache_variant]

    with :ok <- validate_entry(key, value, variant) do
      true = :ets.insert(table(), {{key, variant}, value})
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
      cached_or_generated(key, variant, generator, validator)
    end)
  end

  def fetch_or_generate(_key, _variant, _generator, _validator),
    do: {:error, :generation_key_required}

  # A cached entry that no longer describes the input it was stored for is
  # dropped rather than returned, so the next reader generates a fresh one.
  defp cached_or_generated(key, variant, generator, validator) do
    case get(key, variant: variant) do
      {:ok, value} ->
        if validator.(value) do
          {:ok, value}
        else
          delete_variant(key, variant)
          generate_and_store(key, variant, generator)
        end

      {:error, reason} when reason in [:not_found, :invalid] ->
        generate_and_store(key, variant, generator)

      error ->
        error
    end
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

  defp get_variant(key, variant) do
    case :ets.lookup(table(), {key, variant}) do
      [{_entry_key, value}] ->
        if valid_cache_value?(key, value) and value[:cache_variant] == variant do
          {:ok, value}
        else
          delete_variant(key, variant)
          {:error, :invalid}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp delete_variant(key, variant) do
    :ets.delete(table(), {key, variant})
    :ok
  end

  defp validate_entry(key, value, variant) do
    cond do
      not is_binary(variant) or variant == "" -> {:error, :invalid}
      value[:cache_variant] != variant -> {:error, :invalid}
      not valid_cache_value?(key, value) -> {:error, :invalid}
      true -> :ok
    end
  end

  defp valid_cache_value?(key, value) when is_map(value) do
    candidate = value[:candidate_markdown]

    is_binary(candidate) and Digest.sha256(candidate) == value[:candidate_sha256] and
      value[:generation_key] == key
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
