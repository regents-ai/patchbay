# The browser walk's people, on the walk's own local database: the person the walk
# signs in as, with four paired agents, a second person whose agent already goes by
# "taken-name", a person who saves their public name, a moderator (serve.sh puts their wallet on the moderator list), and
# one person per screen width for the moderator to suspend and reinstate, whose
# public ids go in admin-people.json. Writes the signed cookie the walk sends for
# each person it signs in as. Run by playwright.config.ts before the server
# starts; PatchbayDev.WalkDatabase refuses any database but the walk's local one.
alias Patchbay.Accounts.SessionAuthority
alias Patchbay.Identity

PatchbayDev.WalkDatabase.own!(Patchbay.Repo.config())

person =
  Identity.upsert_from_privy!(%{
    privy_user_id: "did:privy:browser-walk",
    wallet_address: "0x" <> String.duplicate("b", 40)
  })

other =
  Identity.upsert_from_privy!(%{
    privy_user_id: "did:privy:browser-walk-other",
    wallet_address: "0x" <> String.duplicate("c", 40)
  })

if other.agent_name != "taken-name",
  do: Identity.rename_agent!(other, %{agent_name: "taken-name"}, actor: other)

# Four agents paired the way an agent pairs, none of them active yet: the account
# menu shows the three paired last and leaves out Spare Agent, paired first
# (account_menu.spec.ts).
for {name, digit} <- [
      {"Spare Agent", "1"},
      {"Walk Agent", "2"},
      {"Desktop Agent", "3"},
      {"Phone Agent", "4"}
    ] do
  code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person.privy_user_id})

  RegentAgents.pair_agent!(code.code, name, :hermes,
    actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate(digit, 40)}
  )
end

options = Plug.Session.init(store: :cookie, key: "_patchbay_key", signing_salt: "8IPnb8sh")

# In this run's own folder, so two walks at once never sign in as each other's people.
folder = "assets/test/browser/.auth/#{System.fetch_env!("PATCHBAY_DEV_PARTITION")}"
File.mkdir_p!(folder)

# Playwright's own saved-sign-in shape, which the walk's signed-in tests load. The
# cookie holds a sign-in bound to the profile, as the sign-in step leaves it
# (`Patchbay.Accounts.SessionAuthority`).
signed_in = fn profile, file ->
  {:bootstrap, claim} = SessionAuthority.renew(nil)
  {:ok, :bind, claim} = SessionAuthority.sign_in(claim, profile.id, DateTime.utc_now())

  request =
    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, PatchbayWeb.Endpoint.config(:secret_key_base))
    |> Plug.Session.call(options)
    |> Plug.Conn.fetch_session()

  conn =
    claim
    |> SessionAuthority.session()
    |> Enum.reduce(request, fn {key, value}, conn -> Plug.Conn.put_session(conn, key, value) end)
    |> Plug.Conn.send_resp(200, "")

  %{value: value} = conn.resp_cookies["_patchbay_key"]

  File.write!(
    "#{folder}/#{file}.json",
    Jason.encode!(%{
      cookies: [
        %{
          name: "_patchbay_key",
          value: value,
          domain: "127.0.0.1",
          path: "/",
          expires: -1,
          httpOnly: true,
          secure: false,
          sameSite: "Lax"
        }
      ],
      origins: []
    })
  )
end

signed_in.(person, "person")

# A person who saves their Public Display Name (public_name.spec.ts), with the
# account and shared profile their sign-in gives them
# (`Patchbay.Accounts.establish/1`) and a point, so they are on the Points board.
# Their name is as long as a name may be, with no space to break at, as
# public_name.spec.ts saves it too, so every page that names them shows whether
# it fits the screen (long_name.spec.ts).
namer =
  Identity.upsert_from_privy!(%{
    privy_user_id: "did:privy:browser-walk-namer",
    wallet_address: "0x" <> String.duplicate("d", 40)
  })

now = System.system_time(:second)

namer_session = %RegentPrivy.Session{
  app_id: Patchbay.Identity.Privy.app_id(),
  session_id: "browser-walk-namer",
  privy_user_id: namer.privy_user_id,
  wallet_address: namer.wallet_address,
  wallet_addresses: [namer.wallet_address],
  issued_at: now,
  expires_at: now + 600
}

{:ok, namer_account} = Patchbay.Accounts.establish(namer_session)
owner = RegentIdentity.Owner.of(namer_session)

RegentIdentity.get_my_profile!(actor: owner)
|> RegentIdentity.edit_profile!(%{display_name: String.pad_trailing("Walk namer", 80, "W")},
  actor: owner
)

Ash.Seed.seed!(RegentPoints.Account, %{id: namer_account.id, balance_micro: 1_000_000})

signed_in.(namer, "namer")

# The moderator's admin page for a person (person_admin.spec.ts).
Identity.upsert_from_privy!(%{
  privy_user_id: "did:privy:browser-walk-moderator",
  wallet_address: "0x" <> String.duplicate("9", 40)
})
|> signed_in.("moderator")

people =
  Map.new(~w(desktop phone small-phone), fn width ->
    wallet = "0x" <> Base.encode16(:crypto.hash(:sha, "admin-person-" <> width), case: :lower)

    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:browser-walk-admin-person-#{width}",
        wallet_address: wallet
      })

    {width, profile.public_id}
  end)

File.write!("#{folder}/admin-people.json", Jason.encode!(people))
