defmodule Patchbay.Forum.Capabilities.Contract do
  @moduledoc """
  Where the four files of the agent contract disagree, in words: the
  capability rows (`priv/capabilities.json`), the tool manifest
  (`priv/tool_manifest.json`), the OpenAPI document and `cli/commands.json`.
  `Patchbay.Forum.Capabilities` runs it when it compiles and refuses to
  compile while any problem stands, so drift between them fails the build.
  """

  @agents ~w(signed_agent paired_agent)
  @to_person ~w(owner_only wallet)
  @changes_nothing ~w(read quote)

  @typedoc "The four decoded files."
  @type files :: %{capabilities: map(), manifest: map(), openapi: map(), commands: map()}

  @doc "Every disagreement between the four files, one line each; empty when they agree."
  @spec problems(files()) :: [String.t()]
  def problems(files) do
    openapi = operations(files.openapi)
    rows = Map.new(files.capabilities["operations"], &{&1["operation"], &1})

    listed(files.capabilities, rows, openapi) ++
      Enum.flat_map(files.capabilities["operations"], &row_problems(&1, files.capabilities)) ++
      Enum.flat_map(files.manifest["tools"], &tool_problems(&1, rows, openapi)) ++
      Enum.flat_map(files.commands["commands"], &command_problems(&1, rows, openapi, files)) ++
      released_without_command(files)
  end

  @doc "Every OpenAPI operation, by id, as `METHOD /path`."
  @spec operations(map()) :: %{String.t() => String.t()}
  def operations(openapi) do
    for {path, methods} <- openapi["paths"],
        {method, %{"operationId" => id}} <- methods,
        into: %{},
        do: {id, "#{String.upcase(method)} #{path}"}
  end

  defp listed(capabilities, rows, openapi) do
    missing = Map.keys(openapi) -- Map.keys(rows)
    unknown = Map.keys(rows) -- Map.keys(openapi)
    twice = length(capabilities["operations"]) - map_size(rows)

    Enum.map(missing, &"#{&1} is in OpenAPI but has no row in priv/capabilities.json") ++
      Enum.map(unknown, &"#{&1} in priv/capabilities.json is not an OpenAPI operation") ++
      if(twice > 0, do: ["priv/capabilities.json lists an operation twice"], else: [])
  end

  defp row_problems(row, capabilities) do
    names = fn key -> Enum.map(capabilities[key], & &1["name"]) end

    [
      row["authority"] not in names.("authorities") && "an unknown authority",
      not Enum.all?(row["conditions"], &(&1 in names.("conditions"))) && "an unknown condition",
      row["switch"] && row["switch"] not in names.("switches") && "an unknown switch"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&"#{row["operation"]} in priv/capabilities.json has #{&1}")
  end

  # A tool with no operation runs on the page itself: it sends nothing, so it
  # signs nothing and changes nothing, and no server offers it.
  defp tool_problems(tool, _rows, _openapi) when not is_map_key(tool, "operation_id") do
    [
      {tool["hosted"] != false, "no operation_id, yet /mcp lists it"},
      {tool["scope"] != "site" and not String.starts_with?(tool["scope"], "page:"),
       "no operation_id, yet it is offered off the page"},
      {tool["authentication"] != "public", "no operation_id, yet it signs"},
      {tool["annotations"]["readOnlyHint"] != true, "no operation_id, yet it changes something"}
    ]
    |> first()
    |> Enum.map(&tool_says(tool, &1))
  end

  defp tool_problems(tool, rows, openapi) do
    case rows[tool["operation_id"]] do
      nil ->
        [tool_says(tool, "an operation_id OpenAPI does not have")]

      row ->
        [
          {address(tool["route"]) != address(openapi[row["operation"]]),
           "a route other than its operation's"},
          {tool["authentication"] == "siwa_per_request" != row["authority"] in @agents,
           "a signature its operation's authority does not ask for"},
          {tool["authentication"] == "owner_only" != row["authority"] in @to_person,
           "an owner door its operation's authority does not have"},
          {tool["annotations"]["readOnlyHint"] == true != row["effect"] in @changes_nothing,
           "a read-only hint its operation's effect contradicts"},
          {offered_to_agents?(tool) and row["authority"] in @to_person,
           "an agent surface for an operation only its person runs"}
        ]
        |> first()
        |> Enum.map(&tool_says(tool, &1))
    end
  end

  # A page's own tools and /mcp's are agents'; the person's own actions are not.
  defp offered_to_agents?(tool), do: tool["hosted"] != false or tool["scope"] == "site"

  defp tool_says(tool, problem), do: "#{tool["name"]} in priv/tool_manifest.json has #{problem}"

  defp command_problems(command, rows, openapi, files) do
    case rows[command["operation_id"]] do
      nil ->
        [command_says(command, "an operation_id OpenAPI does not have")]

      row ->
        runs = Map.new(files.manifest["tools"], &{&1["name"], &1["operation_id"]})

        [
          {"#{command["method"]} #{command["path"]}" != openapi[row["operation"]],
           "a route other than its operation's"},
          {command["effect"] != row["effect"], "an effect other than its operation's"},
          {command["authority"] != row["authority"], "an authority other than its operation's"},
          {is_binary(command["webmcp"]) and runs[command["webmcp"]] != row["operation"],
           "a browser tool that runs another operation"},
          {not released?(row), "no cli_release or cli_pending in priv/capabilities.json"}
        ]
        |> first()
        |> Enum.map(&command_says(command, &1))
    end
  end

  defp command_says(command, problem),
    do: "`#{command["command"]}` in cli/commands.json has #{problem}"

  # The first of `checks` that holds, as a one-item list; none holds, none.
  defp first(checks) do
    case Enum.find(checks, &elem(&1, 0)) do
      {true, problem} -> [problem]
      nil -> []
    end
  end

  defp released_without_command(files) do
    commanded = MapSet.new(files.commands["commands"], & &1["operation_id"])

    for row <- files.capabilities["operations"],
        released?(row),
        row["operation"] not in commanded,
        do: "#{row["operation"]} in priv/capabilities.json names a release but has no command"
  end

  defp released?(row), do: is_binary(row["cli_release"]) or row["cli_pending"] == true

  # A route's parameters are named for the field that fills them in the
  # manifest and for the record in OpenAPI; the address is the same.
  defp address(nil), do: nil
  defp address(route), do: String.replace(route, ~r/\{[^}]+\}/, "{}")
end
