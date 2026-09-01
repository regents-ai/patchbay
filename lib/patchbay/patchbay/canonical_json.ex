defmodule Patchbay.Patchbay.CanonicalJSON do
  @moduledoc """
  Small, deterministic JSON encoder for the values that make up Patchbay
  contracts and invocation evidence.

  The encoder deliberately accepts only JSON-shaped values. Atoms are written
  as strings so that the same contract can be hashed before and after it has
  crossed the Ash boundary.
  """

  @spec encode(term()) :: binary()
  def encode(value), do: encode_value(value)

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_binary(value), do: Jason.encode!(value)
  defp encode_value(value) when is_atom(value), do: value |> Atom.to_string() |> Jason.encode!()
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)

  defp encode_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 20])

  defp encode_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_value/1) <> "]"
  end

  defp encode_value(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.map(fn {key, item} -> {key_to_string(key), item} end)
    |> reject_duplicate_keys()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> encode_value(item) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> encode_value()

  defp encode_value(value) do
    raise ArgumentError, "cannot encode #{inspect(value)} as canonical JSON"
  end

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp reject_duplicate_keys(entries) do
    Enum.reduce(entries, %{}, fn {key, item}, acc ->
      if Map.has_key?(acc, key) do
        raise ArgumentError, "duplicate canonical JSON key #{inspect(key)}"
      end

      Map.put(acc, key, item)
    end)
    |> Map.to_list()
  end
end
