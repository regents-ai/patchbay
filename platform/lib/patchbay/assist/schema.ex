defmodule Patchbay.Assist.Schema do
  @moduledoc """
  Whether a set of arguments fits the top level of a tool's input schema:
  every required field present, no field the schema shuts out, and each
  named field of the type and, where given, the value the schema says.

  Deeper levels are not checked; the site's own tool is the judge of those,
  and its answer is read as such.
  """

  @doc "The first rule the arguments break, or `:ok`."
  @spec check(map(), map() | nil) :: :ok | {:error, String.t()}
  def check(arguments, nil) when is_map(arguments), do: :ok

  def check(arguments, schema) when is_map(arguments) and is_map(schema) do
    properties = if is_map(schema["properties"]), do: schema["properties"], else: %{}
    required = if is_list(schema["required"]), do: schema["required"], else: []

    with :ok <- required_present(arguments, required),
         :ok <- no_extras(arguments, properties, schema["additionalProperties"]) do
      typed(arguments, properties)
    end
  end

  def check(_arguments, _schema), do: {:error, "arguments must be an object of named values"}

  defp required_present(arguments, required) do
    case Enum.reject(required, &Map.has_key?(arguments, &1)) do
      [] -> :ok
      missing -> {:error, "missing: " <> Enum.join(missing, ", ")}
    end
  end

  defp no_extras(arguments, properties, false) do
    case Map.keys(arguments) -- Map.keys(properties) do
      [] -> :ok
      extra -> {:error, "not taken: " <> Enum.join(extra, ", ")}
    end
  end

  defp no_extras(_arguments, _properties, _allowed), do: :ok

  defp typed(arguments, properties) do
    Enum.find_value(arguments, :ok, fn {name, value} -> broken(name, value, properties[name]) end)
  end

  defp broken(name, value, rule) when is_map(rule) do
    case fits(value, rule) do
      :ok -> nil
      {:error, why} -> {:error, "#{name}: #{why}"}
    end
  end

  defp broken(_name, _value, _unnamed), do: nil

  defp fits(value, %{"enum" => allowed} = rule) when is_list(allowed) do
    if value in allowed,
      do: fits(value, Map.delete(rule, "enum")),
      else: {:error, "not one of the allowed values"}
  end

  defp fits(value, %{"type" => types}) when is_list(types) do
    if Enum.any?(types, &of_type?(value, &1)),
      do: :ok,
      else: {:error, "must be of type " <> Enum.join(types, " or ")}
  end

  defp fits(value, %{"type" => type}) when is_binary(type) do
    if of_type?(value, type), do: :ok, else: {:error, "must be of type " <> type}
  end

  defp fits(_value, _untyped), do: :ok

  defp of_type?(value, "string"), do: is_binary(value)
  defp of_type?(value, "integer"), do: is_integer(value)
  defp of_type?(value, "number"), do: is_number(value)
  defp of_type?(value, "boolean"), do: is_boolean(value)
  defp of_type?(value, "object"), do: is_map(value)
  defp of_type?(value, "array"), do: is_list(value)
  defp of_type?(value, "null"), do: is_nil(value)
  defp of_type?(_value, _unknown_type), do: true
end
