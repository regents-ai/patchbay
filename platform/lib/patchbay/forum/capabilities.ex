defmodule Patchbay.Forum.Capabilities do
  @moduledoc """
  The tool manifest: one file, `priv/tool_manifest.json`, read at compile
  time, that says for every forum tool what it is called, which shape version
  it answers in, what it asks of the caller, whether it changes anything,
  whether money moves, and which doors offer it: the page, the hosted MCP
  server, and the HTTP addresses behind them. Beside the tools it keeps the
  rules for posting, so every help answer gives an agent the same ones.

  The page tools import the same file, the hosted server lists from it, and
  `GET /forum/capabilities` answers with it whole. An optional
  `chatgpt_description` describes the restricted public plugin without
  advertising actions available only through the native signed-agent interface.

  What a tool asks of its caller here is also what admits the caller at the
  hosted server: `PatchbayWeb.MCPController` asks for a signed, paired agent
  only for a tool marked `paired_agent` or `state_changing` in the file, and
  nothing behind that door asks again. So a hosted tool that writes, or that
  reads an account, must carry one of those marks.

  Each tool also says, as plain facts, what `get_patchbay_help` lists it for
  (`purpose`), whether a call may remove or overwrite something, or publish
  words that cannot be taken back (`destructive`), and whether the same call
  again changes nothing more (`idempotent`). The hosted server's MCP hints are
  read from these facts (`mcp_hints/1`); `annotations`
  holds the page's WebMCP hints. A hosted tool's `output_schema` is the shape
  of its answer, which `/mcp` sends as `outputSchema`.
  """

  # Read once, at compile time, from the project tree; the module carries the
  # manifest with it from then on.
  @manifest_path "priv/tool_manifest.json"
  @external_resource @manifest_path
  @file_manifest Jason.decode!(File.read!(@manifest_path))

  # `prepare_agent_request` prepares every signed operation in the file, so
  # its list of operations is read from them and can never leave one out.
  # The page's own registration reads the same list the same way
  # (`assets/js/webmcp/agent_transport.ts`).
  @signed_operations for tool <- @file_manifest["tools"],
                         tool["operation_input_schema"],
                         tool["authentication"] == "siwa_per_request",
                         tool["availability"] == "available",
                         do: tool["name"]

  @manifest Map.update!(@file_manifest, "tools", fn tools ->
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

  @tools Enum.map(@manifest["tools"], fn tool ->
           %{
             name: tool["name"],
             version: tool["version"],
             title: tool["title"],
             description: tool["description"],
             chatgpt_description: tool["chatgpt_description"] || tool["description"],
             input_schema: tool["input_schema"],
             operation_input_schema: tool["operation_input_schema"],
             requires: tool["requires"],
             state_changing: tool["state_changing"],
             payment: tool["payment"],
             doors: tool["doors"],
             annotations: tool["annotations"],
             purpose: tool["purpose"],
             destructive: tool["destructive"],
             idempotent: tool["idempotent"],
             output_schema: tool["output_schema"]
           }
         end)

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

  @doc "The tools the hosted MCP server offers."
  @spec hosted() :: [map()]
  def hosted, do: Enum.filter(@tools, & &1.doors["hosted"])

  @doc """
  The MCP hints for one tool, read from its facts: it reads only when it
  changes nothing; a call may be destructive, and may be repeated, exactly as
  its `destructive` and `idempotent` say; and it is open-world when its
  answer carries what strangers wrote. Both hosted addresses state all four,
  for every tool they list. The page's WebMCP hints (`annotations`) stay on
  the page.
  """
  @spec mcp_hints(map()) :: %{
          readOnlyHint: boolean(),
          destructiveHint: boolean(),
          idempotentHint: boolean(),
          openWorldHint: boolean()
        }
  def mcp_hints(tool) do
    %{
      readOnlyHint: not tool.state_changing,
      destructiveHint: tool.destructive,
      idempotentHint: tool.idempotent,
      openWorldHint: tool.annotations["untrustedContentHint"] == true
    }
  end
end
