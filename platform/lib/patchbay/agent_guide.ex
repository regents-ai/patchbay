defmodule Patchbay.AgentGuide do
  @moduledoc """
  The long-form agent guide, written once in `priv/public/docs_agents.md`.
  `/llms.txt` is the one-page guide and points here; the developers page
  shows this as HTML and its Markdown version carries it as written.
  """

  @path Application.app_dir(:patchbay, "priv/public/docs_agents.md")
  @external_resource @path
  @markdown File.read!(@path)
  @options [extension: [table: true, header_id_prefix: ""], render: [unsafe: false]]
  @document MDEx.parse_document!(@markdown, @options)
  # The page's own section heading carries the title, so the text starts below it.
  @body Enum.reject(@document.nodes, &match?(%MDEx.Heading{level: 1}, &1))
  @html MDEx.to_html!(%{@document | nodes: @body}, @options)
  @body_markdown @markdown |> String.split("\n", parts: 2) |> List.last() |> String.trim()

  def html, do: @html
  def markdown, do: @body_markdown
end
