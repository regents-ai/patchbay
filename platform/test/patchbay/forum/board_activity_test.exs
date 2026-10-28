defmodule Patchbay.Forum.BoardActivityTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum.BoardActivity
  alias PatchbayWeb.SignedAgent

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
