defmodule PatchbayWeb.MCPArgumentsPropertyTest do
  @moduledoc """
  Every hosted tool's input schema, held against arguments generated from it
  and from its negations:

  - arguments the schema allows pass the check and reach the tool;
  - arguments that break one rule are refused once, as a tool result with
    code `invalid` whose details name the field, and never with a 5xx;
  - the tool's HTTP door refuses the same broken arguments.

  The schemas are the manifest's (`Patchbay.Forum.Capabilities.hosted/0`),
  the same ones the page's `prepare_agent_request` reads.
  """

  use PatchbayWeb.ConnCase, async: false
  use ExUnitProperties

  alias Patchbay.Forum.Capabilities
  alias PatchbayWeb.MCP.Arguments
  alias PatchbayWeb.SignedAgent

  # The site directory's web address is also the page people search from:
  # a search past the schema's length is shortened there, not refused.
  @shortened [{"read_site_directory", "q"}, {"read_site_directory", "category"}]

  setup do
    SignedAgent.stub_siwa()
    SignedAgent.stub_wallet_author()
    %{agent: SignedAgent.pair!()}
  end

  property "arguments a hosted schema allows pass, and each broken rule is named" do
    check all(
            {tool, schema} <- tool(),
            arguments <- valid(schema),
            {field, broken} <- broken(schema, arguments),
            max_runs: 500
          ) do
      assert {:ok, _read} = Arguments.check(tool, arguments),
             "#{tool} refused #{inspect(arguments)}"

      assert {:invalid, lines} = Arguments.check(tool, broken)

      assert Enum.any?(lines, &String.starts_with?(&1, field <> ":")),
             "#{tool}: #{inspect(lines)} does not name #{field} for #{inspect(broken)}"

      # Plain words, never the validator's own.
      refute Enum.any?(lines, &(&1 =~ ~r/schema|value |conform|respect/)), inspect(lines)
    end
  end

  property "at /mcp a broken rule is one invalid refusal naming the field, and the HTTP door refuses it too",
           %{conn: conn, agent: agent} do
    check all(
            {tool, schema} <- tool(),
            arguments <- valid(schema),
            {field, broken, http?} <- broken(schema, arguments, :with_door),
            max_runs: 200
          ) do
      answer = conn |> recycle() |> SignedAgent.sign(agent) |> mcp(tool, broken)
      assert answer.status == 200

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               Jason.decode!(answer.resp_body)["result"]

      assert %{"error" => error} = Jason.decode!(text)

      assert error["code"] == "invalid", "#{tool}: #{inspect(error)}"
      assert Enum.any?(error["details"], &String.starts_with?(&1, field <> ":")), tool

      door = http? and {tool, field} not in @shortened and door(tool, broken)

      if door do
        refused = conn |> recycle() |> SignedAgent.sign(agent) |> http(door)

        assert refused.status in 400..499,
               "#{tool}: #{inspect(broken)} broke #{field} but #{elem(door, 0)} " <>
                 "#{elem(door, 1)} answered #{refused.status}"
      end
    end
  end

  property "arguments a hosted schema allows reach the tool and never answer 5xx",
           %{conn: conn, agent: agent} do
    check all({tool, schema} <- tool(), arguments <- valid(schema), max_runs: 150) do
      answer = conn |> recycle() |> SignedAgent.sign(agent) |> mcp(tool, arguments)
      assert answer.status == 200, "#{tool}: #{answer.status}"

      result = Jason.decode!(answer.resp_body)["result"]

      if result["isError"] do
        %{"content" => [%{"text" => text}]} = result
        error = Jason.decode!(text)["error"]

        refute error["code"] == "invalid" and
                 Enum.any?(error["details"], &(&1 =~ "is not a field of this tool")),
               "#{tool} did not reach its tool: #{text}"
      end
    end
  end

  defp tool do
    Capabilities.hosted()
    |> Enum.map(&{&1.name, &1.operation_input_schema || &1.input_schema})
    |> member_of()
  end

  # A value the schema allows.
  defp valid(%{"oneOf" => choices, "properties" => properties}) do
    bind(member_of(choices), fn %{"required" => [field]} ->
      fixed_map(%{field => valid(properties[field])})
    end)
  end

  defp valid(%{"type" => "object", "properties" => properties} = schema) do
    required = Map.get(schema, "required", [])

    {must, may} =
      properties |> Map.new(fn {key, field} -> {key, valid(field)} end) |> Map.split(required)

    bind(fixed_map(must), fn present ->
      map(optional_map(may), &Map.merge(present, &1))
    end)
  end

  defp valid(%{"type" => "object"}),
    do:
      map_of(string(:alphanumeric, min_length: 1, max_length: 6), string(:alphanumeric),
        max_length: 3
      )

  defp valid(%{"enum" => values}), do: member_of(values)
  defp valid(%{"pattern" => pattern}), do: patterned(pattern)
  defp valid(%{"format" => "uuid"}), do: uuid()

  defp valid(%{"format" => "date-time"}),
    do: constant(DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601())

  defp valid(%{"type" => "string"} = field) do
    least = Map.get(field, "minLength", 0)
    most = Map.get(field, "maxLength", 40)

    one_of([
      string(:ascii, min_length: least, max_length: min(most, 40)),
      constant(String.duplicate("a", max(least, most)))
    ])
  end

  defp valid(%{"type" => "integer"} = field),
    do: integer(Map.get(field, "minimum", -5)..Map.get(field, "maximum", 500))

  defp valid(%{"type" => "array", "items" => item} = field),
    do:
      uniq_list_of(valid(item),
        min_length: Map.get(field, "minItems", 0),
        max_length: min(Map.get(field, "maxItems", 3), 3)
      )

  # The patterns the hosted schemas use, each with values that match it.
  defp patterned("^[a-z0-9][a-z0-9-]{0,79}$"), do: string(?a..?z, min_length: 1, max_length: 20)

  defp patterned("^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"),
    do: string(:alphanumeric, min_length: 1, max_length: 20)

  defp patterned("^[a-z][a-z0-9-]*$"), do: string(?a..?z, min_length: 3, max_length: 20)

  defp patterned("^\\S+$"), do: string(:alphanumeric, min_length: 1, max_length: 10)

  defp patterned("^https?://" <> _rest),
    do: map(string(:alphanumeric, min_length: 1, max_length: 8), &"https://example.com/#{&1}")

  defp patterned("^(?:[a-f0-9]{64})?$"), do: member_of(["", String.duplicate("a1", 32)])
  defp patterned("^[a-f0-9]{64}$"), do: constant(String.duplicate("b2", 32))
  defp patterned("^H[0-9]{1,15}$"), do: map(integer(1..999), &"H#{&1}")
  defp patterned("^W[0-9]{1,15}$"), do: map(integer(1..999), &"W#{&1}")

  defp patterned("^[a-f0-9]{8}-[a-f0-9]{4}-" <> _rest), do: uuid()

  defp uuid, do: map(binary(length: 16), &(&1 |> Ecto.UUID.load() |> elem(1)))

  # `arguments` with one rule broken, and the field the refusal must name;
  # `:with_door` also says whether the HTTP door can be sent the same input.
  defp broken(schema, arguments, with_door \\ nil) do
    schema
    |> breaks(arguments)
    |> member_of()
    |> bind(& &1)
    |> map(fn {field, broken, door?} ->
      if with_door, do: {field, broken, door?}, else: {field, broken}
    end)
  end

  defp breaks(schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    unknown = [constant({"bogus", Map.put(arguments, "bogus", 1), false})]

    missing =
      for field <- Map.get(schema, "required", []),
          do: constant({field, Map.delete(arguments, field), true})

    two_scopes =
      if schema["oneOf"],
        do: [
          constant(
            {"input",
             Map.merge(arguments, %{
               "site" => "a.example",
               "tool_id" => Ecto.UUID.generate(),
               "thread_id" => Ecto.UUID.generate()
             }), true}
          )
        ],
        else: []

    values =
      for {field, property} <- properties,
          {value, door?} <- outside(property),
          do: constant({field, Map.put(arguments, field, value), door?})

    unknown ++ missing ++ two_scopes ++ values
  end

  # Values a property refuses, each with whether a query string or a JSON
  # body can carry it to the HTTP door as it is.
  defp outside(%{"enum" => values}), do: [{"not-" <> Enum.join(values, "-"), true}]

  defp outside(%{"type" => "string"} = field) do
    [{17, false}] ++
      if(most = field["maxLength"], do: [{String.duplicate("a", most + 1), true}], else: []) ++
      if(Map.get(field, "minLength", 0) > 0, do: [{"", true}], else: []) ++
      if(field["format"] == "uuid", do: [{"not-a-uuid", true}], else: [])
  end

  defp outside(%{"type" => "integer"} = field) do
    [{"seven", false}] ++
      if(least = field["minimum"], do: [{least - 1, true}], else: []) ++
      if(most = field["maximum"], do: [{most + 1, true}], else: [])
  end

  defp outside(%{"type" => "array"} = field) do
    [{"one", false}] ++
      if(Map.get(field, "minItems", 0) > 0, do: [{[], true}], else: []) ++
      if(most = field["maxItems"],
        do: [{Enum.map(1..(most + 1), &"item-#{&1}"), true}],
        else: []
      )
  end

  defp outside(%{"type" => "object"}), do: [{"text", false}]

  defp mcp(conn, tool, arguments) do
    post(
      conn,
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: arguments}
      })
    )
  end

  # The tool's HTTP door for `arguments`, as `{method, path, body}`: a
  # signed tool's route with its placeholders filled from its fields and the
  # rest as its JSON body; a public read's address with the rest as its
  # query. nil when a path field is missing or not text.
  defp door(tool, arguments) do
    manifest = Enum.find(Capabilities.tools(), &(&1.name == tool))

    case {manifest.route, Capabilities.signed?(manifest)} do
      {nil, _signed} ->
        nil

      {route, true} ->
        [method, template] = String.split(route, " ")
        signed_door(method, template, arguments)

      {"GET " <> path, false} ->
        read_door(tool, path, arguments)
    end
  end

  @read_paths %{
    "get_thread" => %{"id" => "thread_id"},
    "get_known_fix" => %{"id" => "fix_id"},
    "get_agent_profile" => %{"public_id" => "profile_id"},
    "read_tool_catalog" => %{"host" => "host", "name" => "name"},
    "read_wallet_bench_pair" => %{"harness_id" => "harness_id", "wallet_id" => "wallet_id"}
  }

  defp read_door(tool, path, arguments) do
    names = Map.get(@read_paths, tool, %{})

    with {:ok, path, rest} <- fill(path, arguments, names) do
      {"GET", query(path, rest), nil}
    end
  end

  defp signed_door(method, template, arguments) do
    names =
      ~r/\{([a-z_]+)\}/
      |> Regex.scan(template, capture: :all_but_first)
      |> Map.new(fn [field] -> {field, field} end)

    with {:ok, path, rest} <- fill(template, arguments, names) do
      if method == "GET",
        do: {method, query(path, rest), nil},
        else: {method, path, Jason.encode!(rest)}
    end
  end

  defp query(path, rest) when rest == %{}, do: path
  defp query(path, rest), do: path <> "?" <> URI.encode_query(rest)

  defp fill(template, arguments, names) do
    Enum.reduce_while(names, {:ok, template, arguments}, fn {placeholder, field},
                                                            {:ok, path, rest} ->
      case Map.fetch(rest, field) do
        {:ok, value} when is_binary(value) and value not in ["", ".", ".."] ->
          {:cont,
           {:ok,
            String.replace(path, "{#{placeholder}}", URI.encode(value, &URI.char_unreserved?/1)),
            Map.delete(rest, field)}}

        _missing ->
          {:halt, nil}
      end
    end)
  end

  # A door that raises to its error page answers with that page's status.
  defp http(conn, {method, path, body}) do
    conn
    |> put_req_header("accept", "application/json")
    |> dispatch(PatchbayWeb.Endpoint, String.downcase(method) |> String.to_atom(), path, body)
  rescue
    error -> %{status: Plug.Exception.status(error)}
  end
end
