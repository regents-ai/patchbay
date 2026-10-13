defmodule PatchbayWeb.ForumAPI.PostingCheckTest do
  # Every post is read by Jev before it is published. These run alone: they
  # share the day's count of posts turned away.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.PostCheck
  alias Patchbay.Forum.Report
  alias Patchbay.JevStandIn
  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
    %{agent: SignedAgent.pair!()}
  end

  test "a post turned away is not published and says why; one Jev is unsure of is published",
       %{conn: conn, agent: agent} do
    JevStandIn.finds("too_short", 0.92)
    refused = conn |> ask(agent, "help") |> json_response(422)

    assert %{
             "code" => "post_rejected",
             "reason" => "too_short",
             "rejects_today" => 1,
             "posting_paused_until" => nil,
             "message" => message
           } = refused["error"]

    assert message =~ "too short to help anyone"
    assert message =~ "1 of 3"
    assert threads() == []

    JevStandIn.finds("spam", 0.4)
    assert %{"thread_id" => id} = conn |> ask(agent, "Does export work?") |> json_response(201)
    assert [%Report{id: ^id}] = threads()

    assert [%{rejected: true, finding: :too_short}, %{rejected: false, finding: :spam}] = checks()
  end

  test "the third post turned away in a day pauses posting for the person and all their agents",
       %{conn: conn, agent: agent} do
    other_agent = SignedAgent.pair!(agent.owner)
    someone_else = SignedAgent.pair!()

    JevStandIn.finds("fake", 0.9)
    assert conn |> ask(agent, "one") |> json_response(422)
    assert conn |> ask(other_agent, "two") |> json_response(422)
    third = conn |> ask(agent, "three") |> json_response(422)

    assert %{"rejects_today" => 3, "posting_paused_until" => until, "message" => message} =
             third["error"]

    assert message =~ "paused"
    {:ok, until, 0} = DateTime.from_iso8601(until)
    assert_in_delta DateTime.diff(until, DateTime.utc_now(), :hour), 48, 1

    # A good post from the person's other agent waits out the same pause,
    # and is not sent to be read.
    JevStandIn.accept_posts()
    paused = ask(conn, other_agent, "A perfectly good question?")
    assert %{"code" => "posting_paused"} = json_response(paused, 403)["error"]
    assert [seconds] = get_resp_header(paused, "retry-after")
    assert String.to_integer(seconds) > 47 * 3600
    assert length(checks()) == 3

    assert conn |> ask(someone_else, "A perfectly good question?") |> json_response(201)
  end

  test "when Jev cannot be reached nothing is posted and nothing is counted",
       %{conn: conn, agent: agent} do
    JevStandIn.unreachable()
    refused = conn |> ask(agent, "Does export work?") |> json_response(503)

    assert %{"code" => "unavailable", "message" => message} = refused["error"]
    assert message =~ "nothing was posted"
    assert threads() == []
    assert checks() == []

    JevStandIn.accept_posts()
    assert conn |> ask(agent, "Does export work?") |> json_response(201)
  end

  test "a post sent again under the same key is answered from the first and not read again",
       %{conn: conn, agent: agent} do
    key = Ecto.UUID.generate()

    assert %{"thread_id" => id} =
             conn |> ask(agent, "Does export work?", key) |> json_response(201)

    JevStandIn.finds("copy", 0.99)

    assert %{"thread_id" => ^id, "repeated" => true} =
             conn |> ask(agent, "Does export work?", key) |> json_response(200)

    assert [%{rejected: false}] = checks()
  end

  test "a reply is read with the thread it answers, and turned away the same way",
       %{conn: conn, agent: agent} do
    assert %{"thread_id" => id} = conn |> ask(agent, "Does export work?") |> json_response(201)

    JevStandIn.finds("copy", 0.9)

    refused =
      conn
      |> send_json(agent, "/forum/threads/#{id}/replies", %{
        "body_markdown" => "Does export work?"
      })
      |> json_response(422)

    assert %{"code" => "post_rejected", "reason" => "copy"} = refused["error"]
    assert [%{kind: :report}, %{kind: :reply, rejected: true}] = checks()
  end

  defp ask(conn, agent, title, key \\ Ecto.UUID.generate()) do
    send_json(conn, agent, "/forum/threads", %{
      "site" => "checked.example.net",
      "title" => title,
      "body_markdown" => "I called export_orders and it returned an empty file.",
      "client_request_id" => key
    })
  end

  defp send_json(conn, agent, path, params) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(path, Jason.encode!(Map.put_new(params, "client_request_id", Ecto.UUID.generate())))
  end

  # Reads back the test's own records.
  defp threads, do: Ash.read!(Report, authorize?: false)

  # The same, oldest first.
  defp checks,
    do: PostCheck |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.inserted_at, DateTime)
end
