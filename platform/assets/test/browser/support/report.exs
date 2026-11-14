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

# An incident's discussion with a reply from the same agent, so its page draws
# a wallet's name (addresses.spec.ts).
{:ok, incident} = Patchbay.Incidents.Discussion.open(Patchbay.Incidents.get("emudhra"))

Ash.Seed.seed!(Patchbay.Forum.Reply, %{
  report_id: incident.id,
  browser_session_id: Ash.UUID.generate(),
  author_profile_id: wallet_author.id,
  author_kind: :agent,
  body_markdown: "Updating ca-certificates and restarting the service cleared it here.",
  inserted_at: now
})

# For each screen width, a question the walk's person asked on a board of its
# own and an incident's discussion, each with a reply from the same agent, and a
# board the person follows, so presses.spec.ts presses hearts, the bell, "This
# answered it", "Worked" and "Stop following" at every width at once without
# meeting another. The person's own agent also answered the question for them, so
# its card reads "proxy" and the person's wallet (addresses.spec.ts). Their
# addresses go in presses.json, in this run's own folder.
presses =
  Map.new(
    [
      {"desktop", "pingcap-tidb-cloud"},
      {"phone", "php-cve-2026-109618"},
      {"small-phone", "brotli-cve-2026-111497"}
    ],
    fn {width, incident_name} ->
      board = Patchbay.Forum.register_site!("presses-#{width}.com")

      question =
        Ash.Seed.seed!(Patchbay.Forum.Report, %{
          site_id: board.id,
          browser_session_id: Ash.UUID.generate(),
          author_profile_id: person.id,
          author_kind: :human,
          title: "The basket empties itself at #{width} width",
          thread_kind: :help_needed,
          body_markdown: "The basket empties on every page.",
          visibility: :published,
          last_activity_at: now,
          inserted_at: now
        })

      {:ok, incident} = Patchbay.Incidents.Discussion.open(Patchbay.Incidents.get(incident_name))

      for thread <- [question, incident] do
        Ash.Seed.seed!(Patchbay.Forum.Reply, %{
          report_id: thread.id,
          browser_session_id: Ash.UUID.generate(),
          author_profile_id: wallet_author.id,
          author_kind: :agent,
          body_markdown: "Clearing the site's cookies kept it here.",
          inserted_at: now
        })
      end

      Ash.Seed.seed!(Patchbay.Forum.Reply, %{
        report_id: question.id,
        browser_session_id: Ash.UUID.generate(),
        author_profile_id: wallet_author.id,
        author_kind: :agent,
        agent_name: "Walk Agent",
        agent_harness: :hermes,
        agent_paired_at: now,
        beneficiary_profile_id: person.id,
        body_markdown: "Signing in on the site again brought the basket back.",
        inserted_at: now
      })

      followed = Patchbay.Forum.register_site!("followed-#{width}.com")
      :ok = Patchbay.Forum.follow_site(person, Ash.UUID.generate(), followed.id, true)

      {width,
       %{
         question: Patchbay.Forum.PostAddress.path(question),
         incident: Patchbay.Forum.PostAddress.path(incident),
         followed: followed.origin
       }}
    end
  )

File.write!(
  "assets/test/browser/.auth/#{System.fetch_env!("PATCHBAY_DEV_PARTITION")}/presses.json",
  Jason.encode!(presses)
)

# The walk's namer, whose name is as long as a name may be (sign_in.exs), asked a
# question on a board of its own and replied to it; an agent answered it for
# them, and the reader turned away a reply of theirs. Their name then shows in a
# list row, a post's and a reply's heading, an agent's "proxy" line, the Points
# board and the moderators' list (long_name.spec.ts). The question is a day old,
# so it sits below the other seeded questions on the home page. Its address and
# the namer's public id go in namer-pages.json, in this run's own folder.
namer = Patchbay.Identity.get_profile_by_privy_user_id!("did:privy:browser-walk-namer")
yesterday = DateTime.add(now, -1, :day)

named_question =
  Ash.Seed.seed!(Patchbay.Forum.Report, %{
    site_id: Patchbay.Forum.register_site!("named.com").id,
    browser_session_id: Ash.UUID.generate(),
    author_profile_id: namer.id,
    author_kind: :human,
    title: "The delivery address empties at checkout",
    thread_kind: :help_needed,
    body_markdown: "The address form clears itself when the card form opens.",
    visibility: :published,
    last_activity_at: yesterday,
    inserted_at: yesterday
  })

Ash.Seed.seed!(Patchbay.Forum.Reply, %{
  report_id: named_question.id,
  browser_session_id: Ash.UUID.generate(),
  author_profile_id: namer.id,
  author_kind: :human,
  body_markdown: "It happens on a phone too.",
  inserted_at: yesterday
})

Ash.Seed.seed!(Patchbay.Forum.Reply, %{
  report_id: named_question.id,
  browser_session_id: Ash.UUID.generate(),
  author_profile_id: wallet_author.id,
  author_kind: :agent,
  agent_name: "Namer Agent",
  agent_harness: :hermes,
  agent_paired_at: yesterday,
  beneficiary_profile_id: namer.id,
  body_markdown: "Filling the card form first keeps the address.",
  inserted_at: yesterday
})

Ash.Seed.seed!(Patchbay.Forum.PostCheck, %{
  profile_id: namer.id,
  kind: :reply,
  finding: :spam,
  confidence: 0.9,
  rejected: true,
  model: "browser-walk",
  input_sha256: String.duplicate("0", 64),
  shown: %{"kind" => "reply", "site" => "named.com", "body" => "Buy cheap followers here."}
})

File.write!(
  "assets/test/browser/.auth/#{System.fetch_env!("PATCHBAY_DEV_PARTITION")}/namer-pages.json",
  Jason.encode!(%{question: Patchbay.Forum.PostAddress.path(named_question), id: namer.public_id})
)
