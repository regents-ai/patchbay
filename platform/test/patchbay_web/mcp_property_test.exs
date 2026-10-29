defmodule PatchbayWeb.MCPPropertyTest do
  @moduledoc """
  Whatever a client sends the two hosted MCP addresses, the answer is
  well-formed JSON-RPC that names the request it answers, and never a server
  error: random methods, ids and arguments, signed by a paired agent or not,
  to `/mcp` and `/chatgpt/mcp`.

  A request with an id JSON-RPC allows (a string or an integer) is answered
  with that id; any other id is answered with null. A request with no id is a
  notification, answered 202 with no body unless it is refused.
  """

  use PatchbayWeb.ConnCase, async: false
  use ExUnitProperties

  alias Patchbay.Forum.Capabilities
  alias PatchbayWeb.SignedAgent

  @methods ~w(initialize server/discover ping events/list events/subscribe events/unsubscribe
              resources/list resources/read tools/list tools/call notifications/initialized)

  # The paying tool verifies a wallet author, as production is set up to.
  setup do
    SignedAgent.stub_siwa()
    SignedAgent.stub_wallet_author()
    %{agent: SignedAgent.pair!()}
  end

  property "every message is answered in well-formed JSON-RPC, and never with a 5xx",
           %{conn: conn, agent: agent} do
    check all(
            path <- member_of(["/mcp", "/chatgpt/mcp"]),
            signed? <- boolean(),
            {id_given?, id} <- id(),
            method <-
              frequency([
                {4, constant("tools/call")},
                {2, member_of(@methods)},
                {1, string(:printable, max_length: 20)}
              ]),
            params <- params(method),
            max_runs: 300
          ) do
      request =
        %{"jsonrpc" => "2.0", "method" => method, "params" => params}
        |> then(&if(id_given?, do: Map.put(&1, "id", id), else: &1))

      conn = recycle(conn)
      conn = if path == "/chatgpt/mcp", do: on_open(conn), else: conn
      conn = if signed?, do: SignedAgent.sign(conn, agent), else: conn

      answer =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(request))

      assert answer.status < 500, "#{answer.status} for #{inspect(request)}"

      if answer.status == 202 do
        refute id_given?
        assert answer.resp_body == ""
      else
        body = Jason.decode!(answer.resp_body)
        assert body["jsonrpc"] == "2.0"
        assert Map.has_key?(body, "id")
        assert body["id"] == echoed(id_given?, id), "id #{inspect(id)}: #{answer.resp_body}"
        assert Enum.count(["result", "error"], &Map.has_key?(body, &1)) == 1

        if error = body["error"] do
          assert is_integer(error["code"]) and is_binary(error["message"])
        end
      end
    end
  end

  defp echoed(true, id) when is_binary(id) or is_integer(id), do: id
  defp echoed(_given?, _id), do: nil

  # Mostly an id JSON-RPC allows; sometimes one it does not, or none at all.
  defp id do
    frequency([
      {6, tuple({constant(true), one_of([integer(), string(:alphanumeric, max_length: 12)])})},
      {1,
       tuple(
         {constant(true),
          one_of([float(), boolean(), constant(nil), list_of(integer(), max_length: 2)])}
       )},
      {1, constant({false, nil})}
    ])
  end

  # Mostly a hosted tool with fields from its own schema, each a value of
  # the type it asks for or anything at all; sometimes a name or arguments
  # that are not one.
  defp params("tools/call") do
    tool =
      frequency([
        {5, Capabilities.hosted() |> Enum.map(&{&1.name, schema(&1)}) |> member_of()},
        {1, tuple({one_of([string(:printable, max_length: 16), integer()]), constant(nil)})}
      ])

    bind(tool, fn {name, schema} ->
      fixed_map(%{
        "name" => constant(name),
        "arguments" => one_of([fields(schema), arguments(), json()])
      })
    end)
  end

  defp params(_method), do: one_of([arguments(), json()])

  defp schema(tool), do: tool.operation_input_schema || tool.input_schema

  defp fields(nil), do: arguments()

  defp fields(%{"properties" => properties}) do
    properties
    |> Map.new(fn {field, property} -> {field, one_of([typed(property), json()])} end)
    |> optional_map()
  end

  defp typed(%{"enum" => values}), do: member_of(values)
  defp typed(%{"type" => "integer"}), do: integer(-5..500)
  defp typed(%{"type" => "boolean"}), do: boolean()

  defp typed(%{"type" => "array"}),
    do: list_of(string(:alphanumeric, max_length: 12), max_length: 3)

  defp typed(%{"type" => "object"}),
    do: map_of(string(:alphanumeric, max_length: 8), json(), max_length: 3)

  defp typed(_string),
    do:
      one_of([
        string(:printable, max_length: 60),
        constant(Ecto.UUID.generate()),
        constant("quiet.example.net")
      ])

  # Field names the hosted tools and events take, and others, with any value.
  defp arguments do
    fields =
      Capabilities.hosted()
      |> Enum.flat_map(&Map.keys((&1.operation_input_schema || &1.input_schema)["properties"]))
      |> Enum.concat(~w(name arguments delivery uri protocolVersion cursor ttlMs))
      |> Enum.uniq()

    map_of(one_of([member_of(fields), string(:alphanumeric, max_length: 8)]), json(),
      max_length: 5
    )
  end

  defp json do
    leaf =
      one_of([
        integer(),
        float(),
        boolean(),
        constant(nil),
        string(:printable, max_length: 40),
        constant(Ecto.UUID.generate())
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(string(:alphanumeric, max_length: 8), child, max_length: 3)
      ])
    end)
  end
end
