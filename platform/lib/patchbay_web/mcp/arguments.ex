defmodule PatchbayWeb.MCP.Arguments do
  @moduledoc """
  Checks a hosted tool's arguments against its input schema in the manifest,
  the same schema the page's `prepare_agent_request` reads, with a standard
  JSON Schema validator (JSV, draft 2020-12, formats asserted).

  A call that fits gets back the arguments as the validator read them (a
  JSON number such as `2.0` is the integer `2`). A call that does not gets one
  line per broken rule, each opening with the field it is about, for the
  `invalid` refusal every door answers with.
  """

  alias Patchbay.Forum.Capabilities

  # Built once, when this module compiles, from the manifest it reads.
  @schemas Map.new(Capabilities.hosted(), fn tool ->
             {tool.name, tool.operation_input_schema || tool.input_schema}
           end)

  @roots Map.new(@schemas, fn {name, schema} -> {name, JSV.build!(schema, formats: true)} end)

  @doc """
  `{:ok, arguments}` when `arguments` fit hosted tool `name`'s input schema,
  or `{:invalid, lines}` naming each field that broke a rule.
  """
  @spec check(String.t(), map()) :: {:ok, map()} | {:invalid, [String.t(), ...]}
  def check(name, arguments) do
    case JSV.validate(arguments, Map.fetch!(@roots, name)) do
      {:ok, read} -> {:ok, read}
      {:error, error} -> {:invalid, lines(error, Map.fetch!(@schemas, name))}
    end
  end

  defp lines(error, schema) do
    %{details: units} = JSV.normalize_error(error)

    units
    |> Enum.flat_map(fn unit ->
      rule = at(schema, unit.schemaLocation)
      Enum.flat_map(unit.errors, &line(&1, field(unit.instanceLocation), rule))
    end)
    |> Enum.uniq()
  end

  # A unit that only says one of its fields or items broke a rule, or that a
  # field is refused by `additionalProperties: false`, repeats a line another
  # unit gives with its field named. A count of fields beside `oneOf` says
  # again what the `oneOf` line says.
  defp line(%{kind: kind}, _field, _rule)
       when kind in [:properties, :items, :boolean_schema],
       do: []

  defp line(%{kind: kind}, _field, %{"oneOf" => _})
       when kind in [:minProperties, :maxProperties],
       do: []

  defp line(%{kind: :required, ctx: %{missing: missing}}, field, _rule),
    do: Enum.map(missing, &"#{join(field, &1)}: is required.")

  defp line(%{kind: :additionalProperties, ctx: %{property: property}}, field, _rule),
    do: ["#{join(field, property)}: is not a field of this tool."]

  defp line(%{kind: kind}, field, rule), do: ["#{label(field)}: #{words(kind, rule)}."]

  defp words(:oneOf, %{"oneOf" => choices}),
    do: "name exactly one of " <> Enum.map_join(choices, ", ", &hd(&1["required"]))

  defp words(:type, %{"type" => type}), do: "must be " <> kind_of(type)
  defp words(:format, %{"format" => "uuid"}), do: "must be a UUID"

  defp words(:format, %{"format" => "date-time"}),
    do: "must be a date and time, such as 2026-10-29T12:00:00Z"

  defp words(:enum, %{"enum" => values}), do: "must be one of " <> Enum.join(values, ", ")
  defp words(:minLength, %{"minLength" => 1}), do: "must not be empty"
  defp words(:minLength, %{"minLength" => n}), do: "must be at least #{n} characters"
  defp words(:maxLength, %{"maxLength" => n}), do: "must be at most #{n} characters"
  defp words(:minimum, %{"minimum" => n}), do: "must be at least #{n}"
  defp words(:maximum, %{"maximum" => n}), do: "must be at most #{n}"
  defp words(:minItems, %{"minItems" => n}), do: "must list at least #{n}"
  defp words(:maxItems, %{"maxItems" => n}), do: "must list at most #{n}"
  defp words(:minProperties, %{"minProperties" => n}), do: "must name at least #{n} fields"
  defp words(:maxProperties, %{"maxProperties" => n}), do: "must name at most #{n} fields"
  defp words(:pattern, _rule), do: "is not in the form this field takes"

  defp kind_of("string"), do: "text"
  defp kind_of("integer"), do: "a whole number"
  defp kind_of("boolean"), do: "true or false"
  defp kind_of("array"), do: "a list"
  defp kind_of("object"), do: "an object"

  # "#/fix/updates/0/at" is the field fix.updates[0].at; "#" is the input itself.
  defp field("#"), do: nil

  defp field("#/" <> path) do
    path
    |> String.split("/")
    |> Enum.map_join(fn segment ->
      if segment =~ ~r/\A\d+\z/, do: "[#{segment}]", else: "." <> segment
    end)
    |> String.trim_leading(".")
  end

  defp join(nil, key), do: key
  defp join(field, key), do: "#{field}.#{key}"

  defp label(nil), do: "input"
  defp label(field), do: field

  defp at(schema, "#"), do: schema

  defp at(schema, "#/" <> pointer),
    do: get_in(schema, pointer |> String.split("/") |> Enum.map(&step/1))

  defp step(segment),
    do: if(segment =~ ~r/\A\d+\z/, do: Access.at(String.to_integer(segment)), else: segment)
end
