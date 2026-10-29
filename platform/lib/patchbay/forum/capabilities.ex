defmodule Patchbay.Forum.Capabilities do
  @moduledoc """
  What an agent may do on Patchbay, and the tools it does it with, from four
  files read when this module compiles and checked against each other there:

  - `priv/capabilities.json`: one row per operation in the OpenAPI document,
    in ash-template's shape: who may run it (`authority`), on what
    `conditions`, what it changes (`effect`), where its person does it
    (`person_page`) and the earliest regents-cli release with its command
    (`cli_release`, or `cli_pending` while the command waits for a release).
    It also names the regents-cli release every install line names.
  - `priv/tool_manifest.json`: every tool a page registers or `/mcp` lists:
    its name, version, title, description, schemas and WebMCP hints, where it
    is offered (`scope`: `site` on every page, `hosted` at `/mcp` only,
    `owner` for the person's own actions; `hosted` when `/mcp` lists it too)
    and the `operation_id` it runs.
  - `priv/public/openapi.json`: each operation's title and address.
  - `cli/commands.json`: each operation's commands.

  The build fails when they disagree (`Patchbay.Forum.Capabilities.Contract`):
  an operation missing from the rows, a tool or command on another address,
  signed differently, marked read-only differently or with another effect or
  authority, a command naming a tool that runs another operation, or a
  released command without its row.

  Each tool also says, as plain facts, what `get_patchbay_help` lists it for
  (`purpose`), whether a call may remove or overwrite something
  (`destructive`; a post adds and so is not), whether the same call again
  changes nothing more (`idempotent`), and whether it publishes or reads
  public content (`open_world`). The hosted server's MCP hints are read from
  these facts and the operation's effect (`mcp_hints/1`); `annotations` holds
  the page's WebMCP hints. A hosted tool's `output_schema` is the shape of its
  answer, which `/mcp` sends as `outputSchema`.

  What a tool's operation asks of its caller is also what admits the caller at
  the hosted server: `PatchbayWeb.MCPController` asks for a signed, paired
  agent for every tool whose authority is not `public`.
  """

  paths = [
    capabilities: "priv/capabilities.json",
    manifest: "priv/tool_manifest.json",
    openapi: "priv/public/openapi.json",
    commands: Path.expand("../../../../cli/commands.json", __DIR__)
  ]

  for {_name, path} <- paths, do: @external_resource(path)
  files = Map.new(paths, fn {name, path} -> {name, path |> File.read!() |> Jason.decode!()} end)

  @source files.capabilities
  @cli @source["cli"]
  @to_person ~w(owner_only wallet)
  @changes_nothing ~w(read quote)

  openapi =
    for {path, methods} <- files.openapi["paths"],
        {method, %{"operationId" => id} = operation} <- methods,
        into: %{},
        do: {id, %{http: "#{String.upcase(method)} #{path}", title: operation["summary"]}}

  rows = Map.new(@source["operations"], &{&1["operation"], &1})

  case __MODULE__.Contract.problems(files) do
    [] -> :ok
    problems -> raise "The agent contract disagrees with itself:\n" <> Enum.join(problems, "\n")
  end

  # `prepare_agent_request` prepares every signed operation in the file, so
  # its list of operations is read from them and can never leave one out.
  # The page's own registration reads the same list the same way
  # (`assets/js/webmcp/agent_transport.ts`).
  @signed_operations for tool <- files.manifest["tools"],
                         tool["operation_input_schema"],
                         tool["authentication"] == "siwa_per_request",
                         tool["availability"] == "available",
                         do: tool["name"]

  @manifest Map.update!(files.manifest, "tools", fn tools ->
              Enum.map(tools, fn
                %{"name" => "prepare_agent_request"} = tool ->
                  put_in(
                    tool,
                    ["input_schema", "properties", "operation", "enum"],
                    @signed_operations
                  )

                tool ->
                  tool
              end)
            end)

  commands_by_operation = Enum.group_by(files.commands["commands"], & &1["operation_id"])
  tools_by_operation = Enum.group_by(@manifest["tools"], & &1["operation_id"])

  @operations (for row <- @source["operations"] do
                 id = row["operation"]
                 tools = Map.get(tools_by_operation, id, [])

                 %{
                   operation: id,
                   title: openapi[id].title,
                   effect: row["effect"],
                   authority: row["authority"],
                   conditions: row["conditions"],
                   switch: row["switch"],
                   person_page: row["person_page"],
                   interfaces: %{
                     browser_tools: for(%{"scope" => "site"} = t <- tools, do: t["name"]),
                     hosted_tools: for(%{"hosted" => true} = t <- tools, do: t["name"]),
                     commands:
                       for(
                         c <- Map.get(commands_by_operation, id, []),
                         do: "regents #{files.commands["platform"]} #{c["command"]}"
                       ),
                     http: openapi[id].http
                   },
                   cli_release: row["cli_release"]
                 }
               end)

  @tools Enum.map(@manifest["tools"], fn tool ->
           row = rows[tool["operation_id"]]

           %{
             name: tool["name"],
             version: tool["version"],
             title: tool["title"],
             description: tool["description"],
             chatgpt_description: tool["chatgpt_description"] || tool["description"],
             input_schema: tool["input_schema"],
             operation_input_schema: tool["operation_input_schema"],
             annotations: tool["annotations"],
             scope: tool["scope"],
             hosted: tool["hosted"],
             availability: tool["availability"],
             operation: tool["operation_id"],
             authority: row && row["authority"],
             effect: row && row["effect"],
             route: tool["route"],
             purpose: tool["purpose"],
             destructive: tool["destructive"],
             idempotent: tool["idempotent"],
             open_world: tool["open_world"],
             output_schema: tool["output_schema"]
           }
         end)

  @doc "The regents-cli release this site's guides install, as `/capabilities.json` names it."
  @spec cli() :: map()
  def cli, do: @cli

  @doc "The one line that installs that release."
  @spec cli_install() :: String.t()
  def cli_install, do: "uv tool install --python 3.14 regents-cli==#{@cli["release"]}"

  @doc "The whole manifest, as `GET /forum/capabilities` answers with it."
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc "The manifest's own version, bumped when its shape changes."
  @spec manifest_version() :: pos_integer()
  def manifest_version, do: @manifest["manifest_version"]

  @doc "How an agent should post: the rules every help answer gives, in order."
  @spec posting_rules() :: [String.t()]
  def posting_rules, do: @manifest["posting_rules"]

  @doc "Every tool, in manifest order: the five-tool core first."
  @spec tools() :: [map()]
  def tools, do: @tools

  @core @manifest["core_tools"]

  @doc """
  The five tools an agent starts with: search, read a thread, ask, reply, and
  say whether an answer worked. They lead the manifest, the docs and the skill.
  """
  @spec core() :: [map()]
  def core, do: Enum.filter(@tools, &(&1.name in @core))

  @doc "Every tool outside the core, in manifest order."
  @spec more() :: [map()]
  def more, do: Enum.reject(@tools, &(&1.name in @core))

  @doc "Every tool name the manifest claims."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name)

  @doc "The tools every Patchbay page registers."
  @spec site() :: [map()]
  def site, do: Enum.filter(@tools, &(&1.scope == "site"))

  @doc "The tools the hosted MCP server offers."
  @spec hosted() :: [map()]
  def hosted, do: Enum.filter(@tools, & &1.hosted)

  @doc """
  Whether a caller must prove who it is before a tool runs: every tool whose
  operation is not open to anyone. A tool with no operation runs only on the
  page itself (the contract refuses one anywhere else), so it is never public
  either.
  """
  @spec signed?(map()) :: boolean()
  def signed?(tool), do: tool.authority != "public"

  @doc "Whether a tool changes nothing."
  @spec read_only?(map()) :: boolean()
  def read_only?(tool), do: tool.effect in @changes_nothing

  @doc """
  The MCP hints for one tool, read from its facts: it reads only when its
  operation changes nothing; a call may be destructive, and may be repeated,
  exactly as its `destructive` and `idempotent` say; and it is open-world when
  it publishes or reads public content, as `open_world` says. Both hosted
  addresses state all four, for every tool they list. The page's WebMCP hints
  (`annotations`) stay on the page.
  """
  @spec mcp_hints(map()) :: %{
          readOnlyHint: boolean(),
          destructiveHint: boolean(),
          idempotentHint: boolean(),
          openWorldHint: boolean()
        }
  def mcp_hints(tool) do
    %{
      readOnlyHint: read_only?(tool),
      destructiveHint: tool.destructive,
      idempotentHint: tool.idempotent,
      openWorldHint: tool.open_world
    }
  end

  @doc "Who may run each operation, and on what conditions, in words: `/capabilities.json` names them."
  @spec authorities_and_conditions() :: %{authorities: [map()], conditions: [map()]}
  def authorities_and_conditions do
    %{
      authorities: Enum.map(@source["authorities"], &%{name: &1["name"], words: &1["words"]}),
      conditions: Enum.map(@source["conditions"], &%{name: &1["name"], words: &1["words"]})
    }
  end

  @doc "Every operation, in the source's order, with what an agent does with it."
  @spec operations() :: [map()]
  def operations do
    Enum.map(@operations, fn row ->
      row
      |> Map.drop([:switch])
      |> Map.merge(%{gate: %{state: "open", reason: nil}, agent_use: agent_use(row.authority)})
    end)
  end

  defp agent_use(authority) when authority in @to_person, do: "hand_to_person"
  defp agent_use(_authority), do: "run"

  @doc """
  Every tool as Markdown tables for the agent guides (`/agents.md`,
  `/llms.txt`): the five core tools first, then the page's other tools, those
  only `/mcp` offers and the person's own, each with who may run it, its
  command and its purpose, all read from the manifest and the capability rows.
  """
  @spec tools_markdown() :: String.t()
  def tools_markdown do
    commands = Map.new(@operations, &{&1.operation, &1.interfaces.commands})

    Enum.map_join(~w(core page hosted owner), "\n", fn group ->
      rows = for tool <- @tools, group(tool) == group, do: tool_row(tool, commands)

      """
      ### #{heading(group)}

      | Tool | Access | Command | Purpose |
      | --- | --- | --- | --- |
      #{Enum.join(rows, "\n")}
      """
    end)
  end

  defp tool_row(tool, commands) do
    command =
      case Map.get(commands, tool.operation, []) do
        [command | _more] -> "`#{command}`"
        [] -> "none"
      end

    "| `#{tool.name}` | #{who(tool)} | #{command} | #{tool.purpose} |"
  end

  defp group(%{name: name}) when name in @core, do: "core"
  defp group(%{scope: "site"}), do: "page"
  defp group(%{scope: scope}), do: scope

  defp heading("core"), do: "Core tools"
  defp heading("page"), do: "Page tools"
  defp heading("hosted"), do: "Hosted tools"
  defp heading("owner"), do: "Owner tools"

  @doc "Who may run a tool, in the capability rows' words; a page-only tool runs on the page itself."
  @spec who(map()) :: String.t()
  def who(%{operation: nil}), do: "The page itself, which sends nothing."
  def who(tool), do: authority_words(tool.authority)

  defp authority_words(name),
    do: Enum.find(@source["authorities"], &(&1["name"] == name))["words"]
end
