defmodule PatchbayWeb.Forum.TwoNamesTest do
  @moduledoc """
  What a profile is called, who may change it, and how a reader tells a
  person's reply from an agent's.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  @contract String.duplicate("c", 64)
  @arguments String.duplicate("d", 64)

  setup do
    site = Forum.register_site!("shop.example.com")
    tool = Forum.observe_tool!(%{site_id: site.id, name: "checkout", contract_sha256: @contract})

    report =
      Forum.file_report!(%{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: "The cart never changed."
      })

    %{site: site, tool: tool, report: report}
  end

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end

  test "a profile starts with two different names, neither of them anybody else's" do
    one = profile("aaa")
    two = profile("bbb")

    assert one.human_name != one.agent_name
    assert one.agent_name != two.agent_name
    assert one.human_name != two.human_name
  end

  test "the names a profile chose survive its next sign-in" do
    one = profile("aaa")
    {:ok, _} = Identity.rename_agent(one, %{agent_name: "kettle"}, actor: one)
    {:ok, _} = Identity.rename_human(one, %{human_name: "morgan"}, actor: one)

    # Signing in again is the same upsert with the same Privy subject and a
    # wallet Privy may have changed. It must find the same profile and leave
    # both chosen names alone, or a rename would last only until the next visit.
    again =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:aaa",
        wallet_address: "0x" <> String.duplicate("f", 40)
      })

    assert again.id == one.id
    assert again.public_id == one.public_id
    assert again.agent_name == "kettle"
    assert again.human_name == "morgan"
    assert again.wallet_address == "0x" <> String.duplicate("f", 40)
  end

  test "a name one profile holds in either half cannot be taken by another" do
    one = profile("aaa")
    two = profile("bbb")

    {:ok, one} = Identity.rename_agent(one, %{agent_name: "kettle"}, actor: one)
    assert one.agent_name == "kettle"

    assert {:error, %Ash.Error.Invalid{}} =
             Identity.rename_agent(two, %{agent_name: "kettle"}, actor: two)

    # The clash is across halves, not only within one: the person behind the
    # other profile cannot take the name that profile's agent posts under.
    assert {:error, %Ash.Error.Invalid{}} =
             Identity.rename_human(two, %{human_name: "kettle"}, actor: two)
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
             Identity.rename_human(one, %{human_name: "kettle"}, actor: nil)
  end

  test "the tool renames the agent half and cannot reach the person's", %{conn: conn} do
    one = profile("aaa")

    answer =
      conn
      |> signed_in(one)
      |> post(~p"/api/me/agent_name", %{"agent_name" => "kettle"})
      |> json_response(200)

    assert answer["renamed"] == true
    assert answer["author"]["agent_name"] == "kettle"

    reloaded = Identity.get_profile!(one.id)
    assert reloaded.agent_name == "kettle"
    assert reloaded.human_name == one.human_name
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

    assert answer["renamed"] == false
    assert answer["error"] =~ "already taken"
    assert answer["next_action"] =~ "lowercase letters"
  end

  test "a signed-out visitor is asked to sign in rather than given a form", %{
    conn: conn,
    report: report
  } do
    html = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

    assert html =~ "Sign in at the top of the page to reply"
    refute html =~ "pb-reply-verdict"
  end

  test "a person's reply is posted under their own name and marked as a person's", %{
    conn: conn,
    report: report
  } do
    one = profile("aaa")
    {:ok, one} = Identity.rename_human(one, %{human_name: "morgan"}, actor: one)

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

    assert html =~ "pb-reply pb-reply-human"
    assert html =~ "morgan"
    assert html =~ "a person"
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

    assert html =~ "pb-reply pb-reply-agent"
    assert html =~ "kettle"
    assert html =~ "an agent"
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

  test "only the owner of a profile is offered the controls that rename it", %{conn: conn} do
    one = profile("aaa")
    two = profile("bbb")

    mine = conn |> signed_in(one) |> get(~p"/agents/#{one.public_id}") |> html_response(200)
    assert mine =~ "What you and your agent are called here"
    assert mine =~ "pb-name-human"
    assert mine =~ "pb-name-agent"

    theirs = conn |> signed_in(two) |> get(~p"/agents/#{one.public_id}") |> html_response(200)
    refute theirs =~ "What you and your agent are called here"
    refute theirs =~ "pb-name-human"

    # Aiming the form at somebody else's page still renames only the profile
    # that is signed in, because the page in the URL is not what is renamed.
    conn
    |> signed_in(two)
    |> post(~p"/agents/#{one.public_id}/names", %{"half" => "agent", "name" => "kettle"})

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
end
