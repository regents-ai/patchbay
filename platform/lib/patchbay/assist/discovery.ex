defmodule Patchbay.Assist.Discovery do
  @moduledoc """
  Finds out what tools the site an assist names actually offers.

  A site that answers as an MCP server is asked directly and its tools can
  be called. A site whose tools live only inside its pages cannot be called
  from here, so the tools its page signs up in its own code, and what the
  directory holds for it from agents' reports, stand in: a call can be
  picked and described, never made, and the answer says so.
  """

  alias Patchbay.Assist.McpClient
  alias Patchbay.Assist.PageTools
  alias Patchbay.Assist.Target
  alias Patchbay.Forum
  alias Patchbay.Forum.Origin

  # The most rows of a site's directory read, newest version of each name first.
  @directory_rows 200

  @type found ::
          {:live, McpClient.client(), [McpClient.tool()]}
          | {:in_pages, [McpClient.tool()]}
          | {:unlisted, atom()}

  @doc "The site's tools, live or found in its pages, or why none are known."
  @spec find(String.t(), keyword()) :: found()
  def find(site_url, opts \\ []) do
    with {:ok, target} <- Target.connect(site_url, opts),
         {:ok, client} <- McpClient.open(target),
         {:ok, [_ | _] = tools} <- McpClient.list_tools(client) do
      {:live, client, tools}
    else
      {:error, :not_mcp} -> in_pages(site_url, opts)
      {:ok, []} -> {:unlisted, :no_tools_offered}
      {:error, :unresolvable} -> {:unlisted, :unresolvable}
      {:error, :not_public} -> {:unlisted, :not_public}
      {:error, _reason} -> {:unlisted, :unreachable}
    end
  end

  # The directory's tools first, since agents' reports carry what each one
  # takes, then any the page's code signs up that the directory lacks. A
  # page that cannot be read leaves the directory's tools to stand alone.
  defp in_pages(site_url, opts) do
    {page_tools, none_because} =
      case PageTools.read(site_url, opts) do
        {:ok, tools} -> {tools, :no_tools_found}
        {:error, reason} -> {[], reason}
      end

    case Enum.uniq_by(from_directory(site_url) ++ page_tools, & &1.name) do
      [] -> {:unlisted, none_because}
      tools -> {:in_pages, tools}
    end
  end

  # The newest version of each tool name the directory holds for the host.
  defp from_directory(site_url) do
    with {:ok, origin} <- Origin.normalize(site_url),
         {:ok, %{id: site_id}} <- Forum.get_site_by_origin(origin),
         {:ok, %{results: [_ | _] = tools}} <-
           Forum.list_tools_for_site(site_id, page: [limit: @directory_rows]) do
      tools
      |> Enum.uniq_by(& &1.name)
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: tool.description || "",
          input_schema: tool.input_schema,
          destructive?: false
        }
      end)
    else
      _nothing_known -> []
    end
  end
end
