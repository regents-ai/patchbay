defmodule PatchbayWeb.Accept do
  @moduledoc false

  @type media :: String.t()

  @doc """
  Picks the produced type the Accept header prefers.

  Ties break by header order, then by the order of `produces`. A missing or
  empty header returns the first produced type. `nil` means the header was
  present and none of the produced types are acceptable.
  """
  @spec preferred(String.t() | nil, [media()]) :: media() | nil
  def preferred(nil, produces), do: List.first(produces)
  def preferred("", produces), do: List.first(produces)

  def preferred(header, produces) when is_binary(header) and is_list(produces) do
    entries = parse(header)

    {best, best_q, _best_pos} =
      Enum.reduce(produces, {nil, -1.0, :infinity}, fn candidate, acc ->
        consider(candidate, entries, acc)
      end)

    if best_q > 0, do: best
  end

  defp consider(candidate, entries, acc) do
    case match_entry(candidate, entries) do
      {entry, pos} when entry.q > 0 -> keep_better(candidate, entry, pos, acc)
      _no_match -> acc
    end
  end

  defp keep_better(candidate, entry, pos, {_, best_q, best_pos} = acc) do
    if entry.q > best_q or (entry.q == best_q and pos < best_pos) do
      {candidate, entry.q, pos}
    else
      acc
    end
  end

  defp match_entry(candidate, entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce({nil, :infinity}, &keep_match(candidate, &1, &2))
    |> matched_pair()
  end

  defp keep_match(candidate, {entry, pos}, acc) do
    if matches?(entry.type, candidate) and better_match?(entry, pos, acc) do
      {entry, pos}
    else
      acc
    end
  end

  defp better_match?(_entry, _pos, {nil, _matched_pos}), do: true

  defp better_match?(entry, pos, {matched, matched_pos}) do
    entry.specificity > matched.specificity or
      (entry.specificity == matched.specificity and pos < matched_pos)
  end

  defp matched_pair({nil, _}), do: nil
  defp matched_pair(pair), do: pair

  defp matches?("*/*", _candidate), do: true

  defp matches?(type, candidate) do
    if String.ends_with?(type, "/*") do
      String.starts_with?(candidate, String.trim_trailing(type, "*"))
    else
      type == candidate
    end
  end

  defp parse(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.map(&parse_one/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_one(raw) do
    case String.split(raw, ";", trim: true) do
      [type | params] -> media_entry(type, params)
      _empty -> nil
    end
  end

  defp media_entry(type, params) do
    type = type |> String.trim() |> String.downcase()

    unless type == "" do
      %{type: type, q: q_value(params), specificity: specificity(type)}
    end
  end

  defp q_value(params) do
    Enum.find_value(params, 1.0, &q_param/1)
  end

  defp q_param(param) do
    case param |> String.trim() |> String.downcase() |> String.split("=", parts: 2) do
      ["q", value] -> parse_q(value)
      _other -> nil
    end
  end

  defp parse_q(value) do
    case Float.parse(value) do
      {q, _} -> min(1.0, max(0.0, q))
      :error -> 1.0
    end
  end

  defp specificity("*/*"), do: 0
  defp specificity(type), do: if(String.ends_with?(type, "/*"), do: 1, else: 2)
end
