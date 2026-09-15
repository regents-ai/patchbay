defmodule PatchbayWeb.MarkdownEngine do
  @moduledoc """
  Compiles the `.md.eex` templates: plain EEx, so nothing is HTML-escaped and
  a value on its own line keeps the blank lines around it that make it a
  paragraph, with the rendered document tidied so that a loop or a condition
  written on its own line leaves no blank line behind it to split a list or a
  table.
  """

  @behaviour Phoenix.Template.Engine

  @impl Phoenix.Template.Engine
  def compile(path, _name) do
    rendered = EEx.compile_file(path, engine: EEx.SmartEngine, trim: false, line: 1)

    quote do
      PatchbayWeb.MarkdownEngine.tidy(unquote(rendered))
    end
  end

  @doc """
  Markdown with no more than one blank line in a row, no blank line between
  two rows of one table or two items of one list, and one newline at the end.
  """
  @spec tidy(iodata()) :: String.t()
  def tidy(rendered) do
    rendered
    |> IO.iodata_to_binary()
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/(\|[^\n]*\|)\n\n(?=\|)/, "\\1\n")
    |> String.replace(~r/^( *(?:[-*]|\d+\.) [^\n]*)\n\n(?= *(?:[-*]|\d+\.) )/m, "\\1\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end
end
