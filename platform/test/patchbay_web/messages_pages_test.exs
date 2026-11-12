defmodule PatchbayWeb.MessagesPagesTest do
  @moduledoc """
  Agent Message on the pages:

  - `/agents` at patchbay.help shows the button and its window, whose three
    texts name the command and the tool the agent files list; a signed-out
    visitor gets no form;
  - a signed-in person leaves a message from the window's form as themselves
    and sees its receipt; a refused one says why and keeps what they typed;
    a sign-in that ran out leaves nothing;
  - `/admin/messages` is not there for a visitor or a signed-in person, and
    shows a moderator every message, newest first, a page at a time;
  - the open address has no Agents page, so no button.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.AssistFixtures, only: [paired_agent: 0]
  import Patchbay.OffersFixtures, only: [moderator: 0]
  import Phoenix.LiveViewTest

  alias Patchbay.Identity
  alias Patchbay.Messages
  alias Patchbay.Messages.Message
  alias PatchbayWeb.Plugs.CurrentProfile

  describe "the Agents page" do
    test "shows the button and three texts that name the listed command and tool",
         %{conn: conn} do
      page = conn |> get("/agents") |> html_response(200) |> LazyHTML.from_document()

      assert page
             |> LazyHTML.query("#pb-agent-message-open[aria-controls=pb-agent-message]")
             |> Enum.count() == 1

      texts =
        page |> LazyHTML.query("dialog#pb-agent-message pre code") |> Enum.map(&LazyHTML.text/1)

      assert [cli, mcp, webmcp] = texts

      %{"command" => command} =
        "../cli/commands.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("commands")
        |> Enum.find(&(&1["operation_id"] == "leaveMessage"))

      tool = Enum.find(Patchbay.Forum.Capabilities.hosted(), &(&1.name == "messages_leave"))

      assert cli =~ "regents patchbay " <> String.replace(command, "<topic>", "agents")
      assert mcp =~ tool.name and webmcp =~ tool.name

      # What each text tells the agent to send is input the tool takes.
      for text <- [mcp, webmcp] do
        [json] = Regex.run(~r/\{.*\}/s, text)
        input = Jason.decode!(json)
        assert input["topic"] == "agents"
        assert Enum.sort(Map.keys(input)) == ~w(body operation_id reply_to topic)
      end

      # Signed out: the texts alone.
      assert page |> LazyHTML.query("#pb-agent-message-person") |> Enum.count() == 0
    end

    test "is not at the open address", %{conn: conn} do
      assert_error_sent(404, fn -> conn |> on_open() |> get("/agents") end)
    end

    test "gives a signed-in person the form", %{conn: conn} do
      page = conn |> signed_in(person!()) |> get("/agents") |> html_response(200)

      assert page
             |> LazyHTML.from_document()
             |> LazyHTML.query("#pb-agent-message-person-form")
             |> Enum.count() == 1
    end
  end

  describe "the person's form" do
    test "leaves a message as the person and shows its receipt", %{conn: conn} do
      person = person!()
      {:ok, view, _html} = form_for(conn, person)

      view
      |> form("#window-person-form", %{
        "message" => %{"body" => "The list misses my agent.", "reply_to" => "me@example.com"}
      })
      |> render_submit()

      assert [%Message{topic: "agents", agent_profile_id: nil} = left] = messages()
      assert {left.person_profile_id, left.body} == {person.id, "The list misses my agent."}
      assert has_element?(view, "#window-person-receipt code", left.id)
      assert view |> element("#window-person-body") |> render() =~ "></textarea>"
    end

    test "says why a message was refused and keeps what was typed", %{conn: conn} do
      {:ok, view, _html} = form_for(conn, person!())
      long = String.duplicate("a", 201)

      html =
        view
        |> form("#window-person-form")
        |> render_submit(%{"message" => %{"body" => "Kept text", "reply_to" => long}})

      assert messages() == []
      assert has_element?(view, "#window-person-reply-to[aria-invalid=true]")
      assert has_element?(view, "#window-person-reply-to-errors p")
      assert html =~ "Kept text"
      refute has_element?(view, "#window-person-receipt")
    end

    test "leaves nothing once the sign-in has run out", %{conn: conn} do
      person = person!()
      {:ok, view, _html} = form_for(conn, person)
      Identity.suspend_profile!(person, "Spam", actor: %{role: :system})

      view
      |> form("#window-person-form")
      |> render_submit(%{"message" => %{"body" => "Too late"}})

      assert messages() == []
      refute has_element?(view, "#window-person-form")
    end

    test "is not drawn for a visitor", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, PatchbayWeb.AgentMessageLive, session: session(%{}))

      refute has_element?(view, "#window-person")
    end
  end

  describe "the team's inbox" do
    test "is not there for a visitor or a signed-in person", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/admin/messages") end)
      assert_error_sent(404, fn -> conn |> signed_in(person!()) |> get("/admin/messages") end)
    end

    test "shows a moderator every message, newest first, with who left it", %{conn: conn} do
      person = person!()
      agent = paired_agent()
      {:ok, older} = leave(person, "First")

      {:ok, %{receipt: %{id: newer}}} =
        Messages.agent_leave_message(
          "agents",
          %{body: "Second", reply_to: "agent@example.com", operation_id: Ecto.UUID.generate()},
          actor: agent,
          context: %{client_key: Ecto.UUID.generate()}
        )

      {:ok, view, html} = conn |> signed_in(moderator()) |> live("/admin/messages")

      ids = html |> LazyHTML.from_document() |> LazyHTML.query("#pb-messages > li")
      assert LazyHTML.attribute(ids, "id") == ["pb-message-#{newer}", "pb-message-#{older.id}"]

      assert has_element?(
               view,
               "#pb-message-#{older.id} a[href='/admin/people/#{person.public_id}']"
             )

      assert has_element?(view, "#pb-message-#{newer}", "agent@example.com")
      assert has_element?(view, "#pb-message-#{newer}", "Second")
      refute has_element?(view, "#pb-messages-older")
    end

    test "pages older messages", %{conn: conn} do
      for n <- 1..6, person = person!(), m <- 1..9, do: {:ok, _left} = leave(person, "#{n}.#{m}")

      {:ok, view, _html} = conn |> signed_in(moderator()) |> live("/admin/messages")
      assert view |> render() |> rows() == 50

      view |> element("#pb-messages-older") |> render_click()
      assert view |> render() |> rows() == 4
      refute has_element?(view, "#pb-messages-older")
    end

    test "says when it holds none", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in(moderator()) |> live("/admin/messages")
      refute has_element?(view, "#pb-messages")
      assert has_element?(view, "#pb-admin-messages .rg-empty")
    end
  end

  defp rows(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#pb-messages > li") |> Enum.count()

  defp leave(person, body) do
    Messages.leave_message(%{topic: "agents", body: body},
      actor: person,
      context: %{client_key: Ecto.UUID.generate()}
    )
  end

  # Read as the test: every message, which only a moderator may read.
  defp messages, do: Ash.read!(Message, authorize?: false)

  defp form_for(conn, person) do
    claim = %{"agent_profile_id" => person.id, "signed_in_at" => System.os_time(:second) - 5}
    live_isolated(conn, PatchbayWeb.AgentMessageLive, session: session(claim))
  end

  defp session(claim) do
    Map.merge(claim, %{
      "site_edition" => :main,
      "visitor" => Ecto.UUID.generate(),
      "id" => "window-person",
      "topic" => "agents"
    })
  end

  defp person! do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:messages-page-#{System.unique_integer([:positive])}",
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id, System.os_time(:second) - 5)
  end
end
