defmodule Patchbay.About do
  @moduledoc """
  The About page, written once in `priv/public/about.md`. The page shows it as
  HTML, answers it as markdown, and `/llms.txt` repeats its Key facts section
  so AI tools read the same facts.
  """

  @path Application.app_dir(:patchbay, "priv/public/about.md")
  @external_resource @path
  @markdown File.read!(@path)
  @options [extension: [table: true], render: [unsafe: false]]
  @document MDEx.parse_document!(@markdown, @options)
  # The page's own header carries the title, so the text starts below it.
  @body Enum.reject(@document.nodes, &match?(%MDEx.Heading{level: 1}, &1))
  @html MDEx.to_html!(%{@document | nodes: @body}, @options)
  [_before, facts] = String.split(@markdown, "\n## Key facts\n")
  @key_facts "## Key facts\n" <> String.trim_trailing(hd(String.split(facts, "\n## ", parts: 2)))

  def html, do: @html
  def markdown, do: @markdown
  def key_facts, do: @key_facts
end
