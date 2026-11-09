defmodule Patchbay.WrittenPages do
  @moduledoc """
  The pages written once as Markdown and built into the release: About
  (`priv/public/about.md`), the Terms of Use (`priv/legal/`) and the long-form
  agent guide (`priv/public/docs_agents.md`). Each page answers both as HTML
  and as its Markdown, and the HTML starts below the first heading, since the
  page's own header carries the title.

  About and the Terms differ by address (`PatchbayWeb.SiteEdition`). The open
  address's About leaves out the Payments section, and it serves its own
  terms (`terms_open.md`): the same promises and limits for the services it
  offers, which name no payments. patchbay.help serves the Regents Labs Terms
  of Use, the text regents.sh serves, copied word for word from the Regents
  repository's `platform/priv/legal/terms.md`; change it there first and
  copy it here.

  `/llms.txt` is the one-page guide and points to the agent guide; it
  repeats About's Key facts and, at patchbay.help, its Payments section, so
  AI tools read the same facts (`facts/1`).
  """

  @about_path Application.app_dir(:patchbay, "priv/public/about.md")
  @guide_path Application.app_dir(:patchbay, "priv/public/docs_agents.md")
  @terms_paths %{
    main: Application.app_dir(:patchbay, "priv/legal/terms.md"),
    open: Application.app_dir(:patchbay, "priv/legal/terms_open.md")
  }

  @external_resource @about_path
  @external_resource @guide_path
  for {_edition, path} <- @terms_paths, do: @external_resource(path)

  # The document below its first heading.
  below_title = fn markdown, options ->
    document = MDEx.parse_document!(markdown, options)
    %{document | nodes: Enum.reject(document.nodes, &match?(%MDEx.Heading{level: 1}, &1))}
  end

  about = File.read!(@about_path)
  [before_payments, payments_on] = String.split(about, "\n## Payments\n")
  [payments, after_payments] = String.split(payments_on, "\n## ", parts: 2)
  [_before, facts] = String.split(about, "\n## Key facts\n")
  key_facts = "## Key facts\n" <> String.trim_trailing(hd(String.split(facts, "\n## ", parts: 2)))

  about_options = [
    extension: [table: true, inline_code_attributes: false],
    render: [unsafe: false]
  ]

  # The About page's text has its addresses cut out (`Patchbay.AddressText.html/1`).
  @about Map.new(
           %{main: about, open: before_payments <> "\n## " <> after_payments},
           fn {edition, markdown} ->
             html = Patchbay.AddressText.html(below_title.(markdown, about_options))
             {edition, %{html: html, markdown: markdown}}
           end
         )

  @facts %{
    main: key_facts <> "\n\n" <> "## Payments\n" <> String.trim_trailing(payments),
    open: key_facts
  }

  @terms Map.new(@terms_paths, fn {edition, path} ->
           markdown = File.read!(path)
           body = below_title.(markdown, extension: [inline_code_attributes: false])
           {edition, %{html: MDEx.to_html!(body, render: [unsafe: false]), markdown: markdown}}
         end)

  guide = File.read!(@guide_path)

  guide_options = [
    extension: [table: true, header_id_prefix: "", inline_code_attributes: false],
    render: [unsafe: false]
  ]

  @agent_guide %{
    html: MDEx.to_html!(below_title.(guide, guide_options), guide_options),
    # The Markdown leaves out the title line too.
    markdown: guide |> String.split("\n", parts: 2) |> List.last() |> String.trim()
  }

  @type page :: %{html: term(), markdown: String.t()}

  @doc "About at `edition`'s address, its HTML as `Patchbay.AddressText` pieces."
  @spec about(:main | :open) :: page()
  def about(edition), do: Map.fetch!(@about, edition)

  @doc "The sections `/llms.txt` repeats at `edition`'s address: Key facts, and at patchbay.help Payments too."
  @spec facts(:main | :open) :: String.t()
  def facts(edition), do: Map.fetch!(@facts, edition)

  @doc "The Terms of Use at `edition`'s address."
  @spec terms(:main | :open) :: page()
  def terms(edition), do: Map.fetch!(@terms, edition)

  @doc "The long-form agent guide the developers page carries."
  @spec agent_guide() :: page()
  def agent_guide, do: @agent_guide
end
