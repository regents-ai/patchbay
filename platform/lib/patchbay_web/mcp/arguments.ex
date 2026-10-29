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
      Enum.flat_map(unit.errors, &line(&1, field(unit.instanceLocation), unit, schema))
    end)
    |> Enum.uniq()
  end

  # A unit that only says one of its fields or items broke a rule, or that a
  # field is refused by `additionalProperties: false`, repeats a line another
  # unit gives with its field named.
  defp line(%{kind: kind}, _field, _unit, _schema)
       when kind in [:properties, :items, :boolean_schema],
       do: []

  defp line(%{kind: :required, ctx: %{missing: missing}}, field, _unit, _schema),
    do: Enum.map(missing, &"#{join(field, &1)}: is required.")

  defp line(%{kind: :additionalProperties, ctx: %{property: property}}, field, _unit, _schema),
    do: ["#{join(field, property)}: is not a field of this tool."]

  defp line(%{kind: :oneOf}, field, unit, schema) do
    choices =
      schema
      |> at(unit.schemaLocation)
      |> Map.fetch!("oneOf")
      |> Enum.flat_map(& &1["required"])

    ["#{label(field)}: name exactly one of #{Enum.join(choices, ", ")}."]
  end

  defp line(%{message: message}, field, _unit, _schema), do: ["#{label(field)}: #{message}."]

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
