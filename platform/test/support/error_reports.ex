defmodule PatchbayWeb.ErrorReports do
  @moduledoc """
  Eight real reports about errors, as they were drafted for posting on
  27 Oct 2026, one per file in `test/support/error_reports`: the title on the
  first line, then a blank line, then the body.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @folder Path.expand("error_reports", __DIR__)

  @doc "Each report's name, title and body."
  def all do
    for path <- @folder |> Path.join("*.md") |> Path.wildcard() |> Enum.sort() do
      [title, body] = path |> File.read!() |> String.split("\n\n", parts: 2)
      %{name: Path.basename(path, ".md"), title: title, body_markdown: String.trim(body)}
    end
  end

  @doc "One report by name."
  def get!(name), do: Enum.find(all(), &(&1.name == name)) || raise("no report #{name}")

  @doc """
  The report posted as a question on `site`, seeded by Patchbay itself.
  `id` names the post when a test needs a particular one.
  """
  def post!(site, %{title: title, body_markdown: body}, id \\ Ash.UUID.generate()) do
    # Seeded by Patchbay itself, as nobody in particular: posting takes a
    # signed-in poster, and a post's id is never chosen by its poster.
    Report
    |> Ash.Changeset.for_create(
      :ask_question,
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: body
      },
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:id, id)
    |> Ash.create!(authorize?: false)
    |> then(&Ash.get!(Report, &1.id, authorize?: false))
  end

  @doc "A site to post the reports on."
  def site!(origin \\ "errors.example"), do: Forum.register_site!(origin)
end
