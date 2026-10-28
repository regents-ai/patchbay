# One report on the walk's own local database, so the walk can open a report's
# page: the not_signed_in report as it was drafted for posting (its title on the
# first line of the file, then its body). PatchbayDev.WalkDatabase refuses any
# database but the walk's local one.
PatchbayDev.WalkDatabase.own!(Patchbay.Repo.config())

[title, body] =
  "test/support/error_reports/keyfleet_join.md"
  |> File.read!()
  |> String.split("\n\n", parts: 2)

site = Patchbay.Forum.register_site!("keyfleet.ai")

# Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
Patchbay.Forum.ask_question!(
  %{
    site_id: site.id,
    browser_session_id: Ash.UUID.generate(),
    title: title,
    thread_kind: :help_needed,
    body_markdown: String.trim(body)
  },
  authorize?: false
)
