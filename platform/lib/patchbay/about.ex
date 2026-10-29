defmodule Patchbay.About do
  @moduledoc """
  The About page, written once in `priv/public/about.md`. The page shows it as
  HTML and answers it as markdown; at the open address
  (`PatchbayWeb.SiteEdition`) both leave out its Payments section.
  `/llms.txt` repeats its Key facts and, at patchbay.help, its Payments section
  so AI tools read the same facts.
  """

  @path Application.app_dir(:patchbay, "priv/public/about.md")
  @external_resource @path
  @markdown File.read!(@path)
  @options [extension: [table: true], render: [unsafe: false]]

  [before_payments, payments_on] = String.split(@markdown, "\n## Payments\n")
  [payments, after_payments] = String.split(payments_on, "\n## ", parts: 2)
  @payments "## Payments\n" <> String.trim_trailing(payments)
  @markdowns %{main: @markdown, open: before_payments <> "\n## " <> after_payments}

  # The page's own header carries the title, so the text starts below it.
  @pages Map.new(@markdowns, fn {edition, markdown} ->
           document = MDEx.parse_document!(markdown, @options)
           body = Enum.reject(document.nodes, &match?(%MDEx.Heading{level: 1}, &1))
           {edition, %{document | nodes: body}}
         end)

  [_before, facts] = String.split(@markdown, "\n## Key facts\n")
  @key_facts "## Key facts\n" <> String.trim_trailing(hd(String.split(facts, "\n## ", parts: 2)))

  @doc "The page's text below its title at `edition`'s address, as a parsed document the page renders."
  def page(edition), do: Map.fetch!(@pages, edition)
  def markdown(edition), do: Map.fetch!(@markdowns, edition)

  @doc "The sections `/llms.txt` repeats at `edition`'s address: Key facts, and at patchbay.help Payments too."
  def facts(:main), do: @key_facts <> "\n\n" <> @payments
  def facts(:open), do: @key_facts
end
