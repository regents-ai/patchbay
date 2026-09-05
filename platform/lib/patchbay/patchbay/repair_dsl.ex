defmodule Patchbay.Patchbay.RepairDSL do
  @moduledoc """
  Strict, data-only parser for the model's bounded repair proposal.

  The result contains only audited atoms and bounded strings. Unknown fields,
  executable-looking metadata, and adapter names outside the allowlist fail
  closed before any Ash resource is written.
  """

  @fields [
    "root_cause",
    "description_replacement",
    "handler_adapter",
    "output_contract_version",
    "postcondition_set",
    "risk_notes"
  ]

  @allowed_adapters %{
    "apply_candidate_to_editor" => :apply_candidate_to_editor
  }

  @allowed_output_contracts ["skill_uplift_verified_v1"]
  @allowed_postconditions ["skill_candidate_written_v1"]

  @spec parse(binary() | map()) :: {:ok, map()} | {:error, atom() | tuple()}
  def parse(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> parse(decoded)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def parse(value) when is_map(value) do
    with {:ok, values} <- normalize_keys(value),
         :ok <- exact_fields(values),
         {:ok, root_cause} <- bounded_text(values["root_cause"], :root_cause, 1_000),
         {:ok, description} <-
           bounded_text(values["description_replacement"], :description_replacement, 1_000),
         {:ok, adapter} <- adapter(values["handler_adapter"]),
         :ok <- output_contract(values["output_contract_version"]),
         :ok <- postcondition(values["postcondition_set"]),
         {:ok, risk_notes} <- risk_notes(values["risk_notes"]) do
      {:ok,
       %{
         root_cause: root_cause,
         description_replacement: description,
         handler_adapter: adapter,
         output_contract_version: values["output_contract_version"],
         postcondition_set: values["postcondition_set"],
         risk_notes: risk_notes
       }}
    end
  end

  def parse(_), do: {:error, :repair_must_be_an_object}

  @spec allowed_adapters() :: [atom()]
  def allowed_adapters, do: Map.values(@allowed_adapters)

  @spec allowed_output_contracts() :: [String.t()]
  def allowed_output_contracts, do: @allowed_output_contracts

  @spec allowed_postconditions() :: [String.t()]
  def allowed_postconditions, do: @allowed_postconditions

  defp normalize_keys(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      key = key_to_string(key)

      cond do
        is_nil(key) -> {:halt, {:error, :repair_key_invalid}}
        Map.has_key?(acc, key) -> {:halt, {:error, :duplicate_repair_key}}
        true -> {:cont, {:ok, Map.put(acc, key, item)}}
      end
    end)
  end

  defp exact_fields(values) do
    keys = Map.keys(values)

    if Enum.sort(keys) == Enum.sort(@fields), do: :ok, else: {:error, :unknown_repair_field}
  end

  defp bounded_text(value, field, max) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:error, {field, :required}}
      byte_size(value) > max -> {:error, {field, :too_long}}
      unsafe_text?(value) -> {:error, {field, :unsafe_text}}
      true -> {:ok, value}
    end
  end

  defp bounded_text(_, field, _max), do: {:error, {field, :must_be_string}}

  defp adapter(value) when is_binary(value) do
    case Map.fetch(@allowed_adapters, value) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, :adapter_not_allowed}
    end
  end

  defp adapter(value) when is_atom(value), do: adapter(Atom.to_string(value))

  defp adapter(_), do: {:error, :adapter_not_allowed}

  defp output_contract(value) when value in @allowed_output_contracts, do: :ok
  defp output_contract(value) when is_atom(value), do: output_contract(Atom.to_string(value))
  defp output_contract(_), do: {:error, :output_contract_not_allowed}

  defp postcondition(value) when value in @allowed_postconditions, do: :ok
  defp postcondition(value) when is_atom(value), do: postcondition(Atom.to_string(value))
  defp postcondition(_), do: {:error, :postcondition_not_allowed}

  defp risk_notes([_, _, _, _, _ | _]), do: {:error, {:risk_notes, :too_many}}

  defp risk_notes(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, notes} ->
      case bounded_text(item, :risk_note, 240) do
        {:ok, item} -> {:cont, {:ok, [item | notes]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      error -> error
    end)
  end

  defp risk_notes(_), do: {:error, {:risk_notes, :must_be_a_list}}

  defp unsafe_text?(value) do
    String.contains?(value, <<0>>) or
      Regex.match?(~r/(?:<\/?script\b|javascript:|https?:\/\/|```|<%|%>)/i, value) or
      String.to_charlist(value)
      |> Enum.any?(&(&1 in 0xE0000..0xE007F))
  end

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(_), do: nil
end
