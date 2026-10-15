defmodule PatchbayWeb.MCP.RepairCard do
  @moduledoc """
  The repair card: the page a ChatGPT-style host shows when
  `render_repair_card` answers. The tool names it in its `_meta.ui.resourceUri`,
  the host reads it once with `resources/read`, and the card draws the
  answer's `structuredContent`, the same free record `get_thread` gives.
  The ChatGPT surface serves the read-only v2 card; native clients retain v1.
  """

  @uri "ui://patchbay/repair-card-v1.html"
  @readonly_uri "ui://patchbay/repair-card-v2.html"
  @mime_type "text/html;profile=mcp-app"

  @spec uri() :: String.t()
  def uri, do: @uri

  @spec uri(:native_mcp | :chatgpt_plugin) :: String.t()
  def uri(:native_mcp), do: @uri
  def uri(:chatgpt_plugin), do: @readonly_uri

  @doc "The card as `resources/list` names it."
  @spec resource() :: map()
  def resource do
    %{
      uri: @uri,
      name: "repair-card",
      title: "Patchbay repair card",
      mimeType: @mime_type
    }
  end

  @spec resource(:native_mcp | :chatgpt_plugin) :: map()
  def resource(surface), do: Map.put(resource(), :uri, uri(surface))

  @doc "The card's page, for `resources/read` of its uri."
  @spec read(term()) :: {:ok, map()} | {:error, integer(), String.t()}
  # The path is the card's fixed file in priv, never a caller's.
  # sobelow_skip ["Traversal.FileModule"]
  def read(requested) when requested in [@uri, @readonly_uri] do
    file = if requested == @uri, do: "repair-card.html", else: "repair-card-readonly.html"
    html = File.read!(Application.app_dir(:patchbay, "priv/mcp/" <> file))

    {:ok,
     %{
       contents: [
         %{
           uri: requested,
           mimeType: @mime_type,
           text: html,
           _meta: %{
             ui: %{
               domain: "https://patchbay.help",
               csp: %{connectDomains: [], resourceDomains: []}
             }
           }
         }
       ]
     }}
  end

  def read(_uri), do: {:error, -32_002, "Resource not found. Call resources/list."}
end
