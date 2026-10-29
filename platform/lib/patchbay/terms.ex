defmodule Patchbay.Terms do
  @moduledoc """
  The terms each address serves. patchbay.help serves the Regents Labs Terms
  of Use, the text regents.sh serves, copied word for word from the Regents
  repository's `platform/priv/legal/terms.md`; change it there first and copy
  it here. The open address (`PatchbayWeb.SiteEdition`) serves its own terms
  from `priv/legal/terms_open.md`: the same promises and limits for the
  services it offers, which name no payments.
  """

  @files %{main: "priv/legal/terms.md", open: "priv/legal/terms_open.md"}

  @documents Map.new(@files, fn {edition, file} ->
               path = Application.app_dir(:patchbay, file)
               @external_resource path
               markdown = File.read!(path)
               document = MDEx.parse_document!(markdown)
               # The page's own header carries the title, so the text starts below it.
               body = Enum.reject(document.nodes, &match?(%MDEx.Heading{level: 1}, &1))

               {edition,
                {markdown, MDEx.to_html!(%{document | nodes: body}, render: [unsafe: false])}}
             end)

  def html(edition), do: @documents |> Map.fetch!(edition) |> elem(1)
  def markdown(edition), do: @documents |> Map.fetch!(edition) |> elem(0)
end
