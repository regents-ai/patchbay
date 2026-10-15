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
  # Inline only canonical palette roles. Cards keep their own typography and
  # need no external assets or broader resource CSP.
  @palette_path Path.join(Mix.Project.deps_paths()[:regent_ui], "assets/css/tokens.json")
  @external_resource @palette_path
  @tokens @palette_path |> File.read!() |> Jason.decode!() |> Map.fetch!("selectors")
  @themes Map.new(~w(dark light), fn mode ->
            roles = Map.fetch!(@tokens, ~s(:root[data-brand="patchbay"][data-theme="#{mode}"]))

            css =
              Enum.map_join(~w(bg fg fg-muted border accent fg-on-accent), ";", fn role ->
                key = "--color-" <> role
                key <> ":" <> Map.fetch!(roles, key)
              end)

            {mode, ":root{color-scheme:#{mode};#{css}}"}
          end)
  @palette @themes["dark"] <> "@media(prefers-color-scheme:light){" <> @themes["light"] <> "}"

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

    html =
      Application.app_dir(:patchbay, "priv/mcp/" <> file)
      |> File.read!()
      |> String.replace("<!-- regent-ui palette -->", "<style>" <> @palette <> "</style>")

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
