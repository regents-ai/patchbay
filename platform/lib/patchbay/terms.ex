defmodule Patchbay.Terms do
  @moduledoc """
  The Regents Labs Terms of Use, which cover patchbay.help. The text is the
  one regents.sh serves, copied word for word from the Regents repository's
  `platform/priv/legal/terms.md`; change it there first and copy it here.
  """

  @path Path.expand("../../priv/legal/terms.md", __DIR__)
  @external_resource @path
  @markdown File.read!(@path)
  @document MDEx.parse_document!(@markdown)
  # The page's own header carries the title, so the text starts below it.
  @html MDEx.to_html!(
          %{@document | nodes: Enum.reject(@document.nodes, &match?(%MDEx.Heading{level: 1}, &1))},
          render: [unsafe: false]
        )

  def html, do: @html
  def markdown, do: @markdown
end
