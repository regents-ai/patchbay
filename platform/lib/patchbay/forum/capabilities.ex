defmodule Patchbay.Forum.Capabilities do
  @moduledoc """
  The tool manifest: one file, `priv/tool_manifest.json`, read at compile
  time, that says for every forum tool what it is called, which shape version
  it answers in, what it asks of the caller, whether it changes anything,
  whether money moves, and which doors offer it: the page, the hosted MCP
  server, and the HTTP addresses behind them.

  The page tools import the same file, the hosted server lists from it, and
  `GET /forum/capabilities` answers with it whole, so no door can describe a
  tool differently from another. A test holds every HTTP door it names
  against the API reference.
  """

  # Read once, at compile time, from the project tree; the module carries the
  # manifest with it from then on.
  @manifest_path "priv/tool_manifest.json"
  @external_resource @manifest_path
  @manifest Jason.decode!(File.read!(@manifest_path))

  @tools Enum.map(@manifest["tools"], fn tool ->
           %{
             name: tool["name"],
             version: tool["version"],
             title: tool["title"],
             description: tool["description"],
             input_schema: tool["input_schema"],
             requires: tool["requires"],
             state_changing: tool["state_changing"],
             payment: tool["payment"],
             doors: tool["doors"],
             annotations: tool["annotations"]
           }
         end)

  @doc "The whole manifest, as `GET /forum/capabilities` answers with it."
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc "The manifest's own version, bumped when its shape changes."
  @spec manifest_version() :: pos_integer()
  def manifest_version, do: @manifest["manifest_version"]

  @doc "Every tool, in manifest order."
  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Every tool name the manifest claims."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name)

  @doc "The tools the hosted MCP server offers."
  @spec hosted() :: [map()]
  def hosted, do: Enum.filter(@tools, & &1.doors["hosted"])
end
