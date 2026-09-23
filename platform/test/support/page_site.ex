defmodule Patchbay.PageSite do
  @moduledoc """
  A site for tests whose WebMCP tools live in its pages: it answers every
  GET from `pages`, a map of path to `{status, headers, body}` or body, and
  anything else it is sent the way a site that is no MCP server does. Every
  name resolves to one public address, and every call is answered here.
  """

  import Plug.Conn

  @address {93, 184, 216, 34}

  @doc "Points assists at a site answering from `pages`, for the rest of the test."
  @spec serve(map()) :: :ok
  def serve(pages) do
    old = Application.get_env(:patchbay, :assist_target)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:patchbay, :assist_target, old) end)

    Application.put_env(:patchbay, :assist_target,
      resolve: fn _host -> [@address] end,
      req_options: [plug: &answer(&1, pages)]
    )
  end

  @doc "A page whose code signs up one tool, `name`, the way a WebMCP page does."
  @spec with_tool(String.t()) :: String.t()
  def with_tool(name) do
    """
    <html><body><script type="module">
    navigator.modelContext.registerTool({name: "#{name}", description: "The #{name} tool.",
      inputSchema: {type: "object"}, execute: async () => ({})})
    </script></body></html>
    """
  end

  @doc "A page with no tools in it."
  @spec without_tools() :: String.t()
  def without_tools, do: "<html><body><p>Nothing to call here.</p></body></html>"

  defp answer(%{method: "GET", request_path: path} = conn, pages) do
    case Map.get(pages, path) do
      nil -> send_resp(conn, 404, "not here")
      {status, headers, body} -> conn |> merge_resp_headers(headers) |> send_resp(status, body)
      body -> send_resp(conn, 200, body)
    end
  end

  defp answer(conn, _pages), do: send_resp(conn, 405, "")
end
