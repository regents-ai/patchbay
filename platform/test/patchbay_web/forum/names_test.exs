defmodule PatchbayWeb.Forum.NamesTest do
  @moduledoc """
  What a person and their agent are called, who may change the agent's name,
  and how a reader tells a person's reply from an agent's.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Plugs.CurrentProfile

  @contract String.duplicate("c", 64)
  @arguments String.duplicate("d", 64)
  @app "names-test-app"

  setup do
    previous_privy = Application.get_env(:patchbay, :privy, [])
    Application.put_env(:patchbay, :privy, Keyword.put(List.wrap(previous_privy), :app_id, @app))
    on_exit(fn -> Application.put_env(:patchbay, :privy, previous_privy) end)

    site = Forum.register_site!("shop.example.com")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: @contract
      })

    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    report =
      Forum.file_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_failure,
          note: "The cart never changed."
        },
        authorize?: false
      )

    %{site: site, tool: tool, report: report}
  end

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
    })
  end

  # The person's Regents account name, as Regents keeps it for this site's app.
  defp regents_name(profile, name) do
    Patchbay.Repo.query!(
      """
      INSERT INTO regent_identity.profiles
        (id, app_id, privy_user_id, display_name, wallet_addresses, proof_issued_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, '{}', 1, now(), now())
      """,
      [Ecto.UUID.bingenerate(), @app, profile.privy_user_id, name]
    )

    Identity.get_profile!(profile.id)
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id)
  end

  test "a person is shown under their Regents account name, else their short wallet" do
    one = profile("aaa")
    assert AgentProfile.name_for(one, :human) == "0xaaaa..aaaa"

    one = regents_name(one, "Morgan Lee")
    assert AgentProfile.name_for(one, :human) == "Morgan Lee"
    assert AgentProfile.own_name(one) == "Morgan Lee"
    assert AgentProfile.name_for(one, :agent) == one.agent_name

    # Two people may show the same name, as on every Regent site.
    two = "bbb" |> profile() |> regents_name("Morgan Lee")
    assert AgentProfile.name_for(two, :human) == "Morgan Lee"
  end

  test "a wallet author is shown under its short wallet address" do
    wallet =
      Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("c", 40)})

    assert AgentProfile.name_for(wallet, :agent) == "0xcccc..cccc"
    assert AgentProfile.own_name(wallet) == "0xcccc..cccc"
  end

  test "an agent's name starts different from every other agent's" do
    one = profile("aaa")
    two = profile("bbb")

    assert one.agent_name != two.agent_name
  end

  test "the agent name a profile chose survives its next sign-in" do
    one = profile("aaa")
    {:ok, _} = Identity.rename_agent(one, %{agent_name: "kettle"}, actor: one)

    # Signing in again is the same upsert with the same Privy subject and a
    # wallet Privy may have changed. It must find the same profile and leave
    # the chosen name alone, or a rename would last only until the next visit.
    again =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:aaa",
        wallet_address: "0x" <> String.duplicate("f", 40)
      })

    assert again.id == one.id
    assert again.public_id == one.public_id
    assert again.agent_name == "kettle"
    assert again.wallet_address == "0x" <> String.duplicate("f", 40)
  end

  test "an agent name one profile holds cannot be taken by another" do
    one = profile("aaa")
    two = profile("bbb")

    {:ok, one} = Identity.rename_agent(one, %{agent_name: "kettle"}, actor: one)
    assert one.agent_name == "kettle"

    assert {:error, %Ash.Error.Invalid{}} =
             Identity.rename_agent(two, %{agent_name: "kettle"}, actor: two)
  end

  test "a name that is not shaped like one is refused" do
    one = profile("aaa")

    for bad <- ["Kettle", "ke", "kettle--pot", "-kettle", String.duplicate("k", 31)] do
      assert {:error, %Ash.Error.Invalid{}} =
               Identity.rename_agent(one, %{agent_name: bad}, actor: one)
    end
  end

  test "only the profile itself may rename it" do
    one = profile("aaa")
    two = profile("bbb")

    assert {:error, %Ash.Error.Forbidden{}} =
             Identity.rename_agent(one, %{agent_name: "kettle"}, actor: two)

    assert {:error, %Ash.Error.Forbidden{}} =
             Identity.rename_agent(one, %{agent_name: "kettle"}, actor: nil)
  end

  test "the tool renames the agent and cannot reach the person's name", %{conn: conn} do
    one = "aaa" |> profile() |> regents_name("Morgan Lee")

    answer =
      conn
      |> signed_in(one)
      |> post(~p"/api/me/agent_name", %{"agent_name" => "kettle"})
      |> json_response(200)

    assert answer["renamed"] == true
    assert answer["author"]["agent_name"] == "kettle"

    assert answer["author"]["display_name"] == "Morgan Lee"

    reloaded = Identity.get_profile!(one.id)
    assert reloaded.agent_name == "kettle"
    assert reloaded.display_name == "Morgan Lee"
  end

  test "the tool says who already has a name it cannot give", %{conn: conn} do
    one = profile("aaa")
    two = profile("bbb")
    {:ok, _} = Identity.rename_agent(one, %{agent_name: "kettle"}, actor: one)

    answer =
      conn
      |> signed_in(two)
      |> post(~p"/api/me/agent_name", %{"agent_name" => "kettle"})
      |> json_response(422)

    assert answer["error"]["code"] == "invalid"
    assert answer["error"]["message"] =~ "already taken"
    assert answer["error"]["hint"] =~ "lowercase letters"
  end

  test "a signed-out visitor is asked to sign in rather than given a form", %{
    conn: conn,
    report: report
  } do
    html = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

    assert html =~ "Sign in at the top of the page to reply"
    refute html =~ "pb-reply-verdict"
  end

  test "a person's reply is posted under their Regents account name and marked as a person's", %{
    conn: conn,
    report: report
  } do
    one = "aaa" |> profile() |> regents_name("Morgan Lee")

    posting =
      conn
      |> signed_in(one)
      |> get(~p"/reports/#{report.id}")

    assert html_response(posting, 200) =~ "pb-reply-verdict"

    posted =
      posting
      |> post(~p"/reports/#{report.id}/replies", %{
        "reply" => %{"verdict" => "verified_failure", "note" => "I saw the same thing."}
      })

    assert redirected_to(posted) =~ "/reports/#{report.id}"

    html = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

    assert html =~ "Morgan Lee"
    assert html =~ ~s(<span class="pb-badge-kind">person</span>)
    assert html =~ "I saw the same thing."
  end

  test "an agent's reply through the tools is marked as an agent's", %{report: report} do
    one = profile("aaa")
    {:ok, one} = Identity.rename_agent(one, %{agent_name: "kettle"}, actor: one)

    Forum.add_reply!(
      %{
        report_id: report.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :verified_failure,
        note: "Same here."
      },
      actor: one
    )

    html = build_conn() |> get(~p"/reports/#{report.id}") |> html_response(200)

    assert html =~ "kettle"
    assert html =~ ~s(<span class="pb-badge-kind">agent</span>)
  end

  test "a person who says nothing about the verdict is told what is missing", %{
    conn: conn,
    report: report
  } do
    one = profile("aaa")

    html =
      conn
      |> signed_in(one)
      |> post(~p"/reports/#{report.id}/replies", %{
        "reply" => %{"verdict" => "", "note" => "Kept for me."}
      })
      |> html_response(200)

    assert html =~ "Say whether the tool worked before you post."
    assert html =~ "Kept for me."
  end

  test "only the owner is offered the controls that rename and fund a profile, in Account",
       %{conn: conn} do
    one = "aaa" |> profile() |> regents_name("Morgan Lee")
    two = profile("bbb")

    mine = conn |> signed_in(one) |> get(~p"/account/profile") |> html_response(200)
    assert mine =~ "What you are called here"
    assert mine =~ "A tip sent to this person"
    assert mine =~ "Regents account name"
    assert mine =~ "Morgan Lee"
    assert mine =~ "pb-name-agent"
    assert mine =~ ~s(id="pb-agent-funding")
    assert mine =~ "Your USDC Balance"
    assert mine =~ "Copy funding request"
    assert mine =~ "Check again"
    # Buying USDC by card is offered only where the page can take a payment.
    refute mine =~ "Add USDC with a card"
    assert card_topup_offered?(conn, one)

    # A person with no Regents account name yet is told so.
    theirs = conn |> signed_in(two) |> get(~p"/account/profile") |> html_response(200)
    assert theirs =~ "Not set"

    # The public page is the same for everyone, its owner included, and goes
    # by the person's Regents account name, not the agent's.
    public = conn |> signed_in(one) |> get(~p"/agents/#{one.public_id}") |> html_response(200)
    assert public =~ ~r"<h1[^>]*>\s*Morgan Lee\s*</h1>"
    assert public =~ "A tip sent to this person"
    refute public =~ "What you are called here"
    refute public =~ ~s(id="pb-agent-funding")

    # The form renames only the profile that is signed in.
    {:ok, view, _html} = conn |> signed_in(two) |> live(~p"/account/profile")

    assert {:error, {:redirect, %{to: "/account/profile"}}} =
             render_submit(view, "rename", %{"name" => "kettle"})

    assert Identity.get_profile!(one.id).agent_name == one.agent_name
    assert Identity.get_profile!(two.id).agent_name == "kettle"
  end

  test "a signed-out visitor cannot post a reply from the page", %{conn: conn, report: report} do
    html =
      conn
      |> post(~p"/reports/#{report.id}/replies", %{
        "reply" => %{"verdict" => "verified_failure", "note" => "No."}
      })
      |> html_response(200)

    assert html =~ "Sign in to reply here"
    assert Forum.list_replies_for_report!(report.id).results == []
  end

  defp card_topup_offered?(conn, profile) do
    previous_privy = Application.get_env(:patchbay, :privy, [])
    previous_rpc = Application.get_env(:regent_payments, :base_rpc_url)

    Application.put_env(
      :patchbay,
      :privy,
      Keyword.put(List.wrap(previous_privy), :app_id, "did:privy:test")
    )

    Application.put_env(:regent_payments, :base_rpc_url, "https://example.com/rpc")

    try do
      conn
      |> signed_in(profile)
      |> get(~p"/account/profile")
      |> html_response(200) =~ "Add USDC with a card"
    after
      Application.put_env(:patchbay, :privy, previous_privy)
      Application.put_env(:regent_payments, :base_rpc_url, previous_rpc)
    end
  end
end
