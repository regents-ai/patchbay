defmodule PatchbayWeb.OpenAPIShape do
  @moduledoc """
  Checks a real answer against the schema openapi.json gives for it, all the
  way down: every key the answer has is described there, every required key is
  present, a null appears only where null is allowed, and each value has the
  type the schema names. Lengths and patterns stay with the schemas' own tests.
  """

  import ExUnit.Assertions

  @doc "The schema openapi.json gives for a route's 200 answer."
  def response_schema(spec, path, content \\ "application/json") do
    schema =
      get_in(spec, ["paths", path, "get", "responses", "200", "content", content, "schema"])

    assert is_map(schema), "openapi.json describes no #{content} answer for GET #{path}"
    schema
  end

  @doc "Asserts that `value` has the shape `schema` describes; `at` names where it is."
  def assert_shape(spec, schema, value, at \\ "answer")

  def assert_shape(spec, %{"$ref" => "#/" <> ref}, value, at),
    do: assert_shape(spec, get_in(spec, String.split(ref, "/")), value, at)

  def assert_shape(spec, %{"allOf" => parts}, value, at),
    do: assert_shape(spec, Enum.reduce(parts, %{}, &merge(spec, &1, &2)), value, at)

  def assert_shape(spec, %{"oneOf" => choices}, value, at) do
    assert Enum.any?(choices, &shaped?(spec, &1, value)),
           "#{at} matches none of the shapes openapi.json allows there: #{inspect(value)}"
  end

  def assert_shape(_spec, schema, nil, at),
    do: assert(null?(schema), "#{at} is null, but openapi.json does not allow null there")

  def assert_shape(spec, %{"properties" => properties} = schema, value, at) when is_map(value) do
    undescribed = Map.keys(value) -- Map.keys(properties)
    assert undescribed == [], "#{at} has #{inspect(undescribed)}, not in openapi.json"
    missing = Map.get(schema, "required", []) -- Map.keys(value)
    assert missing == [], "#{at} lacks #{inspect(missing)}, which openapi.json requires"

    for {key, field} <- value, do: assert_shape(spec, properties[key], field, "#{at}.#{key}")
  end

  def assert_shape(spec, %{"items" => item}, value, at) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} -> assert_shape(spec, item, entry, "#{at}[#{index}]") end)
  end

  def assert_shape(_spec, schema, value, at) do
    assert typed?(schema["type"], value),
           "#{at} is #{inspect(value)}, but openapi.json says #{inspect(schema["type"])}"
  end

  defp shaped?(spec, schema, value) do
    assert_shape(spec, schema, value)
    true
  rescue
    ExUnit.AssertionError -> false
  end

  defp merge(spec, %{"$ref" => "#/" <> ref}, acc),
    do: merge(spec, get_in(spec, String.split(ref, "/")), acc)

  defp merge(_spec, part, acc) do
    acc
    |> Map.merge(Map.drop(part, ["properties", "required"]))
    |> Map.update(
      "properties",
      part["properties"] || %{},
      &Map.merge(&1, part["properties"] || %{})
    )
    |> Map.update("required", part["required"] || [], &(&1 ++ (part["required"] || [])))
  end

  defp null?(%{"type" => types}) when is_list(types), do: "null" in types
  defp null?(%{"type" => type}), do: type == "null"
  defp null?(schema), do: not Map.has_key?(schema, "properties")

  defp typed?(nil, _value), do: true
  defp typed?(types, value) when is_list(types), do: Enum.any?(types, &typed?(&1, value))
  defp typed?("string", value), do: is_binary(value)
  defp typed?("integer", value), do: is_integer(value)
  defp typed?("number", value), do: is_number(value)
  defp typed?("boolean", value), do: is_boolean(value)
  defp typed?("object", value), do: is_map(value)
  defp typed?("array", value), do: is_list(value)
  defp typed?("null", value), do: is_nil(value)
end
