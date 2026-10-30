defmodule PatchbayWeb.Forum.PostPageReadsTest do
  # A post's page reads the post once, with everything shown about it, and
  # its replies in one page read whatever their number: 24 database reads in
  # all, where reading the post twice took 36.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Identity

  setup do
    site = Forum.register_site!("reads.example")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: String.duplicate("a", 64)
      })

    asker = person("asker", "a")
    replier = person("replier", "b")

    post =
      Forum.file_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: String.duplicate("c", 64),
          verdict: :verified_failure,
          note: "The cart never changed."
        },
        actor: asker,
        authorize?: false
      )

    Forum.like!(post.id, nil, actor: replier, authorize?: false)
    %{post: post, asker: asker, replier: replier}
  end

  test "the page reads the post once", %{conn: conn} = context do
    reply(context, 3)

    reads =
      reads_during(fn -> conn |> get(PostAddress.path(context.post)) |> html_response(200) end)

    assert Enum.count(reads, &(&1 == "forum_reports")) == 1
    assert length(reads) <= 24
  end

  test "more replies on the page add no reads", %{conn: conn} = context do
    path = PostAddress.path(context.post)
    reply(context, 1)
    with_one = reads_during(fn -> conn |> get(path) |> html_response(200) end)

    reply(context, 3)
    with_four = reads_during(fn -> conn |> get(path) |> html_response(200) end)

    assert length(with_four) == length(with_one)
  end

  # The tables read while `request` runs, by any process, in the order read.
  defp reads_during(request) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measurements, %{source: source}, _config -> send(test, {:read, source}) end,
      nil
    )

    request.()
    :telemetry.detach(id)
    collect([])
  end

  defp collect(reads) do
    receive do
      {:read, source} -> collect([source | reads])
    after
      0 -> Enum.reverse(reads)
    end
  end

  # Each reply liked by the asker, so every reply carries a like and its author.
  defp reply(%{post: post, asker: asker, replier: replier}, count) do
    for n <- 1..count do
      reply =
        Forum.add_reply!(
          %{
            report_id: post.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :unknown,
            note: "Reply #{n}."
          },
          actor: replier,
          authorize?: false
        )

      Forum.like!(post.id, reply.id, actor: asker, authorize?: false)
    end
  end

  defp person(name, digit) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:#{name}",
      wallet_address: "0x" <> String.duplicate(digit, 40)
    })
  end
end
