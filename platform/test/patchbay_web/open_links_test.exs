defmodule PatchbayWeb.OpenLinksTest do
  @moduledoc """
  No page at the open address (`PatchbayWeb.SiteEdition`) links to a page it
  does not have: every link and form on its main pages, signed out and
  signed in, leads somewhere that answers there.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile

  @contract String.duplicate("a", 64)

  setup do
    site = Forum.register_site!("shop.example.com")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: @contract
      })

    asker =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:open-links",
        wallet_address: "0x" <> String.duplicate("c", 40)
      })

    report =
      Forum.file_priority_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: String.duplicate("c", 64),
          verdict: :verified_failure,
          note: "The cart never changed.",
          priority_amount_atomic: 5_000_000,
          payment_intent_id: Ash.UUID.generate()
        },
        actor: asker
      )

    # A post about Patchbay itself carries a box for agents.
    own_site = Forum.register_site!(Patchbay.Forum.RoomMirror.origin())

    own_tool =
      Forum.observe_tool!(%{
        site_id: own_site.id,
        address: "https://#{own_site.origin}/",
        name: "search_threads",
        contract_sha256: @contract
      })

    own_report =
      Forum.file_priority_report!(
        %{
          tool_id: own_tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: String.duplicate("d", 64),
          verdict: :verified_failure,
          note: "The search never answered.",
          priority_amount_atomic: 5_000_000,
          payment_intent_id: Ash.UUID.generate()
        },
        actor: asker
      )

    pages = [
      "/",
      PostAddress.path(report),
      PostAddress.path(own_report),
      "/sites",
      "/#{site.origin}",
      "/#{site.origin}/tools/checkout",
      AgentProfile.profile_url(asker),
      "/help",
      "/about",
      "/contact"
    ]

    %{pages: pages, asker: asker}
  end

  test "signed out, every link on the open address answers there", %{conn: conn, pages: pages} do
    assert missing_links(on_open(conn), pages) == %{}
  end

  test "signed in, every link on the open address answers there", %{
    conn: conn,
    pages: pages,
    asker: asker
  } do
    conn =
      conn
      |> on_open()
      |> Plug.Test.init_test_session(%{})
      |> PatchbayWeb.Plugs.CurrentProfile.sign_in(asker.id)

    assert missing_links(conn, pages ++ ~w(/account /account/inbox /account/profile)) == %{}
  end

  # Each page with the links on it that lead to a route the open address does
  # not have.
  defp missing_links(conn, paths) do
    for path <- paths,
        html = conn |> get(path) |> html_response(200),
        links = kept_to_main(html),
        links != [],
        into: %{},
        do: {path, links}
  end

  defp kept_to_main(html) do
    document = LazyHTML.from_document(html)

    for {selector, attribute} <- [{"a[href]", "href"}, {"form[action]", "action"}],
        target <- LazyHTML.attribute(LazyHTML.query(document, selector), attribute),
        %URI{host: nil, path: "/" <> _ = path} <- [URI.parse(target)],
        method <- if(selector == "a[href]", do: ["GET"], else: ["POST"]),
        main_only?(method, path),
        uniq: true,
        do: path
  end

  defp main_only?(method, path) do
    case Phoenix.Router.route_info(PatchbayWeb.Router, method, path, "any") do
      %{pipe_through: pipelines} -> :main_only in pipelines
      :error -> false
    end
  end
end
