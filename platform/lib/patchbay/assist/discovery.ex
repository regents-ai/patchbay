defmodule Patchbay.Assist.Discovery do
  @moduledoc """
  Finds out what tools the site an assist names actually offers.

  A site that answers as an MCP server is asked directly and its tools can
  be called. A site whose tools live only inside its pages cannot be
  reached from here, so what Patchbay already knows about it from the
  directory and from agents' reports stands in: a call can be picked and
  described, never made, and the answer says so.
  """

  alias Patchbay.Assist.McpClient
  alias Patchbay.Assist.Run
  alias Patchbay.Assist.Target
  alias Patchbay.Forum
  alias Patchbay.Forum.Origin

  @type found ::
          {:live, McpClient.client(), [McpClient.tool()]}
          | {:directory, [McpClient.tool()]}
          | {:unlisted, atom()}

  @doc "The site's tools, live or from the directory, or why none are known."
  @spec find(Run.t(), keyword()) :: found()
  def find(%Run{site_url: site_url}, opts \\ []) do
    with {:ok, target} <- Target.connect(site_url, opts),
         {:ok, client} <- McpClient.open(target),
         {:ok, [_ | _] = tools} <- McpClient.list_tools(client) do
      {:live, client, tools}
    else
      {:error, :not_mcp} -> from_directory(site_url)
      {:ok, []} -> {:unlisted, :no_tools_offered}
      {:error, :unresolvable} -> {:unlisted, :unresolvable}
      {:error, :not_public} -> {:unlisted, :not_public}
      {:error, _reason} -> {:unlisted, :unreachable}
    end
  end

  # The newest version of each tool name the directory holds for the host.
  defp from_directory(site_url) do
    with {:ok, origin} <- Origin.normalize(site_url),
         {:ok, %{id: site_id}} <- Forum.get_site_by_origin(origin),
         {:ok, [_ | _] = tools} <- Forum.list_tools_for_site(site_id) do
      {:directory,
       tools
       |> Enum.uniq_by(& &1.name)
       |> Enum.map(fn tool ->
         %{
           name: tool.name,
           description: tool.description || "",
           input_schema: tool.input_schema,
           destructive?: false
         }
       end)}
    else
      _nothing_known -> {:unlisted, :no_tools_known}
    end
  end
end
