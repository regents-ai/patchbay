# The browser walk's people, on the walk's own local database: the person the walk
# signs in as, and a second person whose agent already goes by "taken-name". Writes
# the signed cookie the walk sends. Run by playwright.config.ts before the server
# starts; it refuses any database but the walk's local one.
alias Patchbay.Identity

repo = Patchbay.Repo.config()

unless to_string(repo[:hostname]) in ["127.0.0.1", "localhost", "::1"] and
         Regex.match?(~r/\Apatchbay_dev_browser_\d+\z/, to_string(repo[:database])),
       do: raise("the browser walk signs in only on its own local database")

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

conn =
  Plug.Test.conn(:get, "/")
  |> Map.put(:secret_key_base, PatchbayWeb.Endpoint.config(:secret_key_base))
  |> Plug.Session.call(options)
  |> Plug.Conn.fetch_session()
  |> PatchbayWeb.Plugs.CurrentProfile.sign_in(person.id)
  |> Plug.Conn.send_resp(200, "")

%{value: value} = conn.resp_cookies["_patchbay_key"]

File.mkdir_p!("assets/test/browser/.auth")

# Playwright's own saved-sign-in shape, which the walk's signed-in tests load.
File.write!(
  "assets/test/browser/.auth/person.json",
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
