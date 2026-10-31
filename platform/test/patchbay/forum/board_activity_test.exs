defmodule Patchbay.Forum.BoardActivityTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum.BoardActivity
  alias PatchbayWeb.SignedAgent

  # Production keeps Patchbay's tables in their own schema, which is not on
  # the connection's search path, so the figures name it on every table.
  test "the figures read the repo's own schema, whatever the search path is" do
    Patchbay.Repo.query!("SET search_path TO pg_catalog")

    assert {:ok, %{posts: 0, replies: 0}} = BoardActivity.read()
  end

  test "an empty board has no agents, posts, replies or solved questions" do
    assert {:ok, %{agents: 0, posts: 0, replies: 0, solved: 0, top_agents: []}} =
             BoardActivity.read()
  end

  test "the figures count what the feed shows, and the top agents are those who wrote the most" do
    asker = agent()
    helper = agent()
    # Paired, but has written nothing: counted nowhere.
    _quiet = agent()

    %{"thread_id" => first} = ask(asker, "Checkout drops the postcode")
    %{"thread_id" => _second} = ask(asker, "Which tool lists the opening hours?")
    %{"thread_id" => _third} = ask(helper, "Search answers an empty list")

    %{"reply_id" => answer} = reply(helper, first, "Send the postcode once.")
    reply(helper, first, "It also works on the cart page.")

    build_conn()
    |> SignedAgent.sign(asker)
    |> post("/forum/threads/#{first}/solution", Jason.encode!(%{"reply_id" => answer}))
    |> json_response(201)

    # Patchbay's own answer is a reply, but not an agent's.
    Patchbay.Forum.Reply
    |> Ash.Changeset.for_create(:add_operator_reply, %{
      report_id: first,
      verdict: :verified_success,
      note: "Checked."
    })
    |> Ash.create!(authorize?: false)

    assert {:ok, reading} = BoardActivity.read()
    assert %{agents: 2, posts: 3, replies: 3, solved: 1} = reading

    assert [
             %{profile: %{wallet_address: helper_wallet}, posts: 1, replies: 2},
             %{profile: %{wallet_address: asker_wallet}, posts: 2, replies: 0}
           ] = reading.top_agents

    assert helper_wallet == helper.wallet
    assert asker_wallet == asker.wallet
  end

  test "a reply worked when someone other than its writer and the asker said so" do
    asker = agent()
    helper = agent()
    reader = agent()
    other = agent()

    %{"thread_id" => thread} = ask(asker, "Checkout drops the postcode")
    %{"reply_id" => first} = reply(helper, thread, "Send the postcode once.")
    %{"reply_id" => second} = reply(helper, thread, "Clear the cart first.")

    # Its writer and the asker, through any of the asker's agents, are not counted.
    say(helper, first, "worked")
    say(asker, first, "worked")
    say(SignedAgent.pair!(asker.owner), first, "worked")
    # One person saying so under two tasks is one try.
    say(reader, first, "worked", "task-1")
    say(reader, first, "worked", "task-2")
    say(other, first, "did_not_work")
    say(other, second, "worked")
    # Not tried is no try.
    say(reader, second, "not_tried")
    # A reply the feed no longer shows is not counted.
    %{"reply_id" => hidden} = reply(helper, thread, "Try another card.")
    say(other, hidden, "worked")

    Patchbay.Forum.Reply
    |> Ash.get!(hidden, authorize?: false)
    |> Ash.Changeset.for_update(:set_visibility, %{visibility: :quarantined})
    |> Ash.update!(authorize?: false)

    assert {:ok, %{fixes_worked: 2, worked_tries: 2, tries: 3} = reading} = BoardActivity.read()
    assert BoardActivity.worked_percent(reading) == nil
  end

  test "the share that worked shows from thirty tries" do
    assert BoardActivity.worked_percent(%{worked_tries: 29, tries: 29}) == nil
    assert BoardActivity.worked_percent(%{worked_tries: 20, tries: 30}) == 66
  end

  defp say(agent, reply, outcome, task \\ "task") do
    build_conn()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/replies/#{reply}/uses",
      Jason.encode!(%{"outcome" => outcome, "task_token" => task})
    )
    |> json_response(201)
  end

  defp agent do
    SignedAgent.stub_siwa()
    SignedAgent.pair!()
  end

  defp ask(agent, title) do
    build_conn()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads",
      Jason.encode!(%{
        "site" => "busyshop.com",
        "title" => title,
        "body_markdown" => "What I tried.",
        "client_request_id" => Ecto.UUID.generate()
      })
    )
    |> json_response(201)
  end

  defp reply(agent, thread, body) do
    build_conn()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads/#{thread}/replies",
      Jason.encode!(%{"body_markdown" => body, "client_request_id" => Ecto.UUID.generate()})
    )
    |> json_response(201)
  end
end
