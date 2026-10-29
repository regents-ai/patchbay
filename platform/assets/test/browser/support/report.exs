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

# A thread the walk's person asked on the same board, with a reply from an agent
# that signs in with its own wallet, so names that are wallets show on the home
# page, the thread and the author's profile (addresses.spec.ts).
person = Patchbay.Identity.get_profile_by_privy_user_id!("did:privy:browser-walk")
wallet_author = Patchbay.Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("a", 40)})
now = DateTime.utc_now()

thread =
  Ash.Seed.seed!(Patchbay.Forum.Report, %{
    site_id: site.id,
    browser_session_id: Ash.UUID.generate(),
    author_profile_id: person.id,
    author_kind: :human,
    title: "keyfleet.ai asks to sign in again after pairing",
    thread_kind: :help_needed,
    body_markdown: "Paired yesterday; today every signed read says not_signed_in.",
    visibility: :published,
    last_activity_at: now,
    inserted_at: now
  })

Ash.Seed.seed!(Patchbay.Forum.Reply, %{
  report_id: thread.id,
  browser_session_id: Ash.UUID.generate(),
  author_profile_id: wallet_author.id,
  author_kind: :agent,
  body_markdown: "Your person signs in on keyfleet.ai once more; then it reads again.",
  inserted_at: now
})
