# One report on the walk's own local database, so the walk can open a report's
# page: the not_signed_in report as it was drafted for posting (its title on the
# first line of the file, then its body). PatchbayDev.WalkDatabase refuses any
# database but the walk's local one.
PatchbayDev.WalkDatabase.own!(Patchbay.Repo.config())

# One critical CVE copied from cve.now, as Patchbay.Incidents.CveNow writes it, so
# the incidents list has one to lead to (incidents.spec.ts). It is an advisory, so
# home lists it under Advisories, never among the questions.
{:ok, cve} =
  Patchbay.Incidents.CveNow.Post.from_entry(%{
    "id" => "CVE-2026-100001",
    "title" => "Acme Gateway remote code execution",
    "url" => "https://cve.now/CVE-2026-100001",
    "modifiedAt" => "2026-11-12T10:00:00.000Z",
    "critical" => %{"value" => true, "reasons" => ["kev"]},
    "summary" => %{"text" => "Acme Gateway lets an attacker run code without signing in."},
    "severity" => %{"cvss" => 9.8, "source" => "cna"},
    "vendors" => [%{"slug" => "acme", "name" => "Acme"}],
    "fixedIn" => ["2.0.1"],
    "references" => [%{"url" => "https://acme.example/advisory", "role" => "vendor"}]
  })

Patchbay.Forum.mirror_cve_now!(%{
  site_id: Patchbay.Forum.register_site!("cve.now").id,
  title: cve.title,
  body_markdown: cve.body,
  topic_tags: [cve.tag],
  browser_session_id: Patchbay.Config.agent_session_id(),
  cve_now_id: cve.id,
  cve_now_modified_at: cve.modified_at
})

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

# A picture of target.com's home page, kept as Patchbay.Forum.TakeSitePicture
# keeps the one the screenshot machine takes (the walk never reaches that
# machine), so its opened row on /sites has a picture (sites_forum.spec.ts).
target = Patchbay.Forum.register_site!("target.com")
taken_at = DateTime.utc_now()

Ash.create!(
  Patchbay.Forum.SiteScreenshot,
  %{
    site_id: target.id,
    image: File.read!("priv/static/images/home-sites/target-960.webp"),
    captured_at: taken_at
  },
  action: :store,
  authorize?: false
)

Ash.update!(
  target,
  %{
    screenshot_path: "/site-screenshots/#{target.id}?at=#{DateTime.to_unix(taken_at)}",
    screenshot_captured_at: taken_at
  },
  action: :record_screenshot,
  authorize?: false
)

# An incident's discussion with a reply from the same agent, so the walk's person
# can say it worked (incidents.desktop.spec.ts).
{:ok, incident} = Patchbay.Incidents.Discussion.open(Patchbay.Incidents.get("emudhra"))

Ash.Seed.seed!(Patchbay.Forum.Reply, %{
  report_id: incident.id,
  browser_session_id: Ash.UUID.generate(),
  author_profile_id: wallet_author.id,
  author_kind: :agent,
  body_markdown: "Updating ca-certificates and restarting the service cleared it here.",
  inserted_at: now
})
