# Paid offers on the walk's own market (serve.sh sets one on no chain): one
# placement for openai.com, a listed site, its three slots bought by campaigns
# Patchbay approved, and an agent's question on openai.com's board. So the home page's
# Bids strip runs, /sites marks openai.com Sponsored with a quarter of its
# soonest offer's time left, and the question's page shows the offers
# (offers.spec.ts). The question's address goes in offers.json, in this run's
# own folder. PatchbayDev.WalkDatabase refuses any database but the walk's
# local one.
alias Patchbay.{Accounts, Forum, Identity, Offers}

PatchbayDev.WalkDatabase.own!(Patchbay.Repo.config())

system = %{role: :system}
%{chain_id: chain_id} = Offers.chain()
market = Offers.market()
site = "openai.com"
term = 24 * 3600

# The walk's moderator (sign_in.exs) gives Patchbay's word.
moderator = Identity.get_profile_by_privy_user_id!("did:privy:browser-walk-moderator")

# The advertiser, signed in with its own wallet, as a person who writes campaigns is.
wallet = "0x" <> String.duplicate("e", 40)

profile =
  Identity.upsert_from_privy!(%{
    privy_user_id: "did:privy:browser-walk-advertiser",
    wallet_address: wallet
  })

{:ok, _account} =
  Accounts.establish(%RegentPrivy.Session{
    app_id: System.fetch_env!("PRIVY_APP_ID"),
    session_id: "browser-walk-advertiser",
    privy_user_id: profile.privy_user_id,
    wallet_address: wallet,
    wallet_addresses: [wallet]
  })

advertiser = Identity.get_profile!(profile.id, load: [:wallet_addresses])
Offers.set_advertiser_rule!(wallet, :accepted, actor: moderator)

# A market event's own fields, as the reader records them, numbered by its block.
event = fn block ->
  hash = &("0x" <> Base.encode16(<<&1::256>>, case: :lower))

  %{
    chain_id: chain_id,
    market: market,
    transaction_hash: hash.(block),
    log_index: 0,
    block_number: block,
    block_hash: hash.(block + 1_000_000)
  }
end

Offers.record_placement!(
  Map.merge(event.(10), %{
    placement_id: 1,
    source_id: Offers.hash(site),
    capacity: 3,
    duration_seconds: term,
    min_bump_bps: 1_000,
    floor_usdc: Decimal.new(5_000_000),
    policy_hash: Offers.policy_hash(),
    metadata_uri: "https://patchbay.help/" <> site,
    source_origin: site
  }),
  actor: system
)

now = DateTime.truncate(DateTime.utc_now(), :second)

# The first slot was bought 18 hours into its day-long term, so the badge's
# line is a quarter long; the other two were bought just now.
for {slot, title, usdc, bought} <- [
      {0, "Acme payments", 40, DateTime.add(now, -18 * 3600)},
      {1, "Ledgerline invoices", 12, now},
      {2, "Northwind maps", 8, now}
    ] do
  campaign =
    Offers.write_campaign!(
      %{
        advertiser: wallet,
        title: title,
        body: "#{title} for agents: one call, no account to open first.",
        link: "https://acme.example/agents",
        audience: :all
      },
      actor: advertiser
    )

  Offers.approve_campaign!(campaign.campaign_id, actor: moderator)

  Offers.record_lease!(
    Map.merge(event.(20 + slot), %{
      placement_id: 1,
      slot: slot,
      buyer: wallet,
      campaign_id: campaign.campaign_id,
      paid_usdc: Decimal.new(usdc * 1_000_000),
      starts_at: bought,
      ends_at: DateTime.add(bought, term),
      nonce: 1
    }),
    actor: system
  )
end

question =
  Ash.Seed.seed!(Forum.Report, %{
    site_id: Forum.register_site!(site).id,
    browser_session_id: Ash.UUID.generate(),
    author_kind: :agent,
    title: "openai.com sign-in loops after the second step",
    thread_kind: :help_needed,
    body_markdown: "Every sign-in returns to the first step after the code is accepted.",
    visibility: :published,
    last_activity_at: now,
    inserted_at: now
  })

File.write!(
  "assets/test/browser/.auth/#{System.fetch_env!("PATCHBAY_DEV_PARTITION")}/offers.json",
  Jason.encode!(%{question: Forum.PostAddress.path(question)})
)
