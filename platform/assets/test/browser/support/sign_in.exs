# The browser walk's people, on the walk's own local database: the person the walk
# signs in as, a second person whose agent already goes by "taken-name", and one
# person per screen width who saves Offers, since each account saves five wordings
# a day and the widths run at once. Writes the signed cookie the walk sends for
# each person it signs in as. Run by playwright.config.ts before the server
# starts; PatchbayDev.WalkDatabase refuses any database but the walk's local one.
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

options = Plug.Session.init(store: :cookie, key: "_patchbay_key", signing_salt: "8IPnb8sh")

# In this run's own folder, so two walks at once never sign in as each other's people.
folder = "assets/test/browser/.auth/#{System.fetch_env!("PATCHBAY_DEV_PARTITION")}"
File.mkdir_p!(folder)

# Playwright's own saved-sign-in shape, which the walk's signed-in tests load.
signed_in = fn profile, file ->
  conn =
    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, PatchbayWeb.Endpoint.config(:secret_key_base))
    |> Plug.Session.call(options)
    |> Plug.Conn.fetch_session()
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
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

# The saved Offer check signs in as offers-<width>.json (motion.spec.ts).
for {width, wallet} <- [{"desktop", "d"}, {"phone", "e"}, {"small-phone", "f"}] do
  Identity.upsert_from_privy!(%{
    privy_user_id: "did:privy:browser-walk-offers-#{width}",
    wallet_address: "0x" <> String.duplicate(wallet, 40)
  })
  |> signed_in.("offers-#{width}")
end
