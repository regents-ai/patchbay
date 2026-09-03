defmodule Patchbay.ForumTest do
  use Patchbay.DataCase, async: true

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report

  @contract String.duplicate("a", 64)
  @other_contract String.duplicate("b", 64)
  @arguments String.duplicate("c", 64)

  defp site!(origin \\ "example.com"), do: Forum.register_site!(origin)

  defp tool!(site, attrs \\ %{}) do
    Forum.observe_tool!(
      Map.merge(%{site_id: site.id, name: "checkout", contract_sha256: @contract}, attrs)
    )
  end

  defp report_attrs(tool, attrs) do
    Map.merge(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_success
      },
      attrs
    )
  end

  defp report!(tool, attrs \\ %{}), do: Forum.file_report!(report_attrs(tool, attrs))

  defp reply_attrs(report, attrs) do
    Map.merge(
      %{report_id: report.id, browser_session_id: Ash.UUID.generate(), verdict: :unknown},
      attrs
    )
  end

  defp results(%Ash.Page.Keyset{results: results}), do: results

  # Only a verified report names a call, and only the forum's own action can
  # mark one. Writing the column straight is how the stored guarantee itself —
  # rather than the path that normally sets it — gets exercised.
  defp name_call(report, invocation_id) do
    Patchbay.Repo.query!(
      "UPDATE forum_reports SET invocation_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(invocation_id), Ecto.UUID.dump!(report.id)]
    )
  end

  defp action_names(resource) do
    resource |> Ash.Resource.Info.actions() |> Enum.map(&{&1.name, &1.type}) |> Enum.sort()
  end

  describe "Origin.normalize/1" do
    accepted = [
      {"https://Shopify.com/path", "shopify.com"},
      {"Shopify.com.:443", "shopify.com"},
      {"//Shopify.com", "shopify.com"},
      {"http://user:pass@evil.com", "evil.com"},
      {"  HTTPS://Shopify.com.:443/a?b=c  ", "shopify.com"},
      {"Shop.Example.CO.UK", "shop.example.co.uk"}
    ]

    for {input, expected} <- accepted do
      test "accepts #{inspect(input)} as #{expected}" do
        assert Origin.normalize(unquote(input)) == {:ok, unquote(expected)}
      end
    end

    rejected = [
      {"javascript:alert(1)", "a scheme fragment"},
      {"data:text/html,<b>hi</b>", "a data URL"},
      {"192.168.1.1", "an IPv4 literal"},
      {"127.0.0.1", "a loopback IPv4 literal"},
      {"http://[2001:db8::1]/x", "an IPv6 literal"},
      {"[::1]", "a bracketed IPv6 literal"},
      {"localhost", "localhost"},
      {"shopify", "a single-label host"},
      {"not a host!", "free text"},
      {"", "an empty string"}
    ]

    for {input, description} <- rejected do
      test "rejects #{description}" do
        assert {:error, _message} = Origin.normalize(unquote(input))
      end
    end

    test "rejects a non-string" do
      assert {:error, _message} = Origin.normalize(nil)
    end
  end

  describe "register_site/1" do
    test "normalizes a full URL down to its bare lowercase host" do
      assert %{origin: "shopify.com"} = Forum.register_site!("https://Shopify.com/path")
    end

    test "surfaces a rejected origin as an error on the argument" do
      assert {:error, error} = Forum.register_site("not a host!")
      assert Exception.message(error) =~ "origin"
    end

    test "is idempotent by origin" do
      first = Forum.register_site!("https://Shopify.com/checkout")
      second = Forum.register_site!("http://shopify.com")

      assert first.id == second.id
      assert [_only_one] = results(Forum.list_sites!())
    end

    test "re-registering leaves the stored site untouched" do
      first = Forum.register_site!("shopify.com")
      again = Forum.register_site!("https://shopify.com/anything")

      assert again.id == first.id
      assert again.claim_kind == :none
      assert is_nil(again.claimed_at)
      assert again.inserted_at == first.inserted_at
    end
  end

  describe "site claims" do
    test "start unclaimed and have no action that can set them in v0" do
      site = site!()

      assert site.claim_kind == :none
      assert is_nil(site.claimed_at)

      # Claiming needs an ownership proof that does not exist yet, so no write
      # action may touch these fields. Registering is the only write.
      assert action_names(Patchbay.Forum.Site) ==
               [
                 {:read, :read},
                 {:by_report_count, :read},
                 {:register_site, :create}
               ]
               |> Enum.sort()
    end
  end

  describe "get_site_by_origin/1 and list_sites/0" do
    test "finds a site by its normalized origin" do
      site = Forum.register_site!("https://Shopify.com/path")

      assert {:ok, found} = Forum.get_site_by_origin("shopify.com")
      assert found.id == site.id
    end

    test "orders sites by report count, busiest first" do
      quiet = site!("quiet.example")
      busy = site!("busy.example")

      busy_tool = tool!(busy)
      report!(busy_tool)
      report!(busy_tool)
      report!(tool!(quiet))

      assert [%{id: first}, %{id: second}] =
               results(Forum.list_sites!(load: [:report_count, :tool_count]))

      assert first == busy.id
      assert second == quiet.id
    end

    test "counts tools and reports per site" do
      site = site!()
      report!(tool!(site))
      tool!(site, %{contract_sha256: @other_contract})

      assert {:ok, loaded} =
               Forum.get_site_by_origin("example.com", load: [:tool_count, :report_count])

      assert loaded.tool_count == 2
      assert loaded.report_count == 1
    end

    test "pages through sites with a keyset cursor" do
      site!("one.example")
      site!("two.example")
      site!("three.example")

      first_page = Forum.list_sites!(page: [limit: 2])
      assert length(first_page.results) == 2
      assert first_page.more?

      cursor = List.last(first_page.results).__metadata__.keyset
      second_page = Forum.list_sites!(page: [limit: 2, after: cursor])

      assert length(second_page.results) == 1
      refute second_page.more?

      assert Enum.map(first_page.results ++ second_page.results, & &1.origin) ==
               ["one.example", "three.example", "two.example"]
    end
  end

  describe "observe_tool/1" do
    test "separates contract versions of the same tool name" do
      site = site!()
      first = tool!(site)
      second = tool!(site, %{contract_sha256: @other_contract})

      refute first.id == second.id
      assert length(results(Forum.list_tools_for_site!(site.id))) == 2
    end

    test "upserts on site, name and contract, refreshing recency but not copy" do
      # The copy is part of the digest the row is keyed by, so a later caller
      # reporting the same digest cannot rewrite the words a thread shows.
      site = site!()
      first = tool!(site, %{title: "Checkout", description: "Old copy"})
      second = tool!(site, %{title: "Checkout v2", description: "New copy"})

      assert second.id == first.id
      assert second.title == "Checkout"
      assert second.description == "Old copy"
      assert second.first_seen_at == first.first_seen_at
      assert DateTime.compare(second.last_seen_at, first.last_seen_at) in [:gt, :eq]
      assert [_only_one] = results(Forum.list_tools_for_site!(site.id))
    end

    test "a re-observation that omits the title keeps the stored one" do
      # A bare re-observation cannot blank out copy someone else already saw.
      site = site!()
      tool!(site, %{title: "Checkout", description: "Old copy"})
      refreshed = tool!(site)

      assert refreshed.title == "Checkout"
      assert refreshed.description == "Old copy"
    end

    test "strips control characters from the title and description" do
      tool =
        tool!(site!(), %{title: "Check\u0000out\u200B", description: "Line\aone"})

      assert tool.title == "Checkout"
      assert tool.description == "Lineone"
    end

    test "keeps newlines and tabs in the description" do
      tool = tool!(site!(), %{description: "line one\nline\ttwo"})

      assert tool.description == "line one\nline\ttwo"
    end

    test "rejects a name that is not a lowercase identifier" do
      site = site!()

      assert {:error, error} =
               Forum.observe_tool(%{
                 site_id: site.id,
                 name: "Check-Out",
                 contract_sha256: @contract
               })

      assert Exception.message(error) =~ "name"
    end

    test "rejects a contract digest that is not 64 hex characters" do
      site = site!()

      assert {:error, error} =
               Forum.observe_tool(%{site_id: site.id, name: "checkout", contract_sha256: "abc"})

      assert Exception.message(error) =~ "contract_sha256"
    end

    test "get_tool/1 fetches one tool by id" do
      tool = tool!(site!())

      assert {:ok, found} = Forum.get_tool(tool.id)
      assert found.id == tool.id
    end
  end

  describe "file_report/1" do
    test "what a report says never changes; only its escrow and its accepted answer do" do
      assert action_names(Report) ==
               Enum.sort([
                 {:read, :read},
                 {:for_update, :read},
                 {:for_tools, :read},
                 {:priority_for_tools, :read},
                 {:for_invocation, :read},
                 {:verified_awaiting_repair, :read},
                 {:file_report, :create},
                 {:file_priority_report, :create},
                 {:record_escrow_credit, :update},
                 {:accept_reply, :update},
                 {:record_escrow_release, :update},
                 {:withdraw_priority_report, :update},
                 {:record_escrow_refund, :update}
               ])

      assert action_names(Reply) ==
               Enum.sort([
                 {:read, :read},
                 {:for_report, :read},
                 {:add_reply, :create},
                 {:add_human_reply, :create},
                 {:add_operator_reply, :create},
                 {:set_reward_eligibility, :update}
               ])
    end

    test "a report filed without a receipt is nobody's word but its author's" do
      report = report!(tool!(site!()))

      refute report.verified
      assert report.receipt_status == :missing
      assert report.invocation_id == nil
    end

    test "a receipt nobody was ever handed matches no call" do
      report = report!(tool!(site!()), %{receipt: "Ab3xQ7pL-t2ZmR4nS_1wCg"})

      refute report.verified
      assert report.receipt_status == :unknown
    end

    test "a value that could not be a receipt at all is refused the same way" do
      for value <- ["", "   ", "not a receipt", String.duplicate("x", 5_000)] do
        assert report!(tool!(site!()), %{receipt: value}).receipt_status in [:missing, :unknown]
      end
    end

    test "no two reports can stand on the same call" do
      tool = tool!(site!())
      first = report!(tool)
      second = report!(tool)
      call = Ash.UUID.generate()

      assert %Postgrex.Result{num_rows: 1} = name_call(first, call)

      assert_raise Postgrex.Error, ~r/forum_reports_unique_invocation_index/, fn ->
        name_call(second, call)
      end
    end

    test "stores the reported evidence and verdict" do
      report =
        report!(tool!(site!()), %{
          handler_result: %{"ok" => true},
          observed: %{"cart_total" => "12.00"},
          verdict: :verified_failure,
          failure_code: "CART_NOT_UPDATED",
          note: "The button spun forever."
        })

      assert report.verdict == :verified_failure
      assert report.failure_code == "CART_NOT_UPDATED"
      assert report.handler_result == %{"ok" => true}
      assert {:ok, found} = Forum.get_report(report.id)
      assert found.id == report.id
    end

    test "strips control characters from the note but keeps its line breaks" do
      report = report!(tool!(site!()), %{note: "before\u0000after\nsecond line"})

      assert report.note == "beforeafter\nsecond line"
    end

    test "rejects a note longer than 500 bytes" do
      tool = tool!(site!())

      # 251 two-byte characters: under the 500-character limit, over 500 bytes.
      assert {:error, error} =
               Forum.file_report(report_attrs(tool, %{note: String.duplicate("é", 251)}))

      assert Exception.message(error) =~ "note"
      assert Exception.message(error) =~ "500 bytes"

      assert %{note: note} = report!(tool, %{note: String.duplicate("é", 250)})
      assert byte_size(note) == 500
    end

    test "rejects a failure code longer than 64 bytes" do
      tool = tool!(site!())

      assert {:error, error} =
               Forum.file_report(report_attrs(tool, %{failure_code: String.duplicate("é", 33)}))

      assert Exception.message(error) =~ "failure_code"
      assert Exception.message(error) =~ "64 bytes"

      assert %{failure_code: code} = report!(tool, %{failure_code: String.duplicate("é", 32)})
      assert byte_size(code) == 64
    end

    test "accepts evidence at exactly 8192 bytes and rejects one byte more" do
      tool = tool!(site!())

      # Canonical JSON of %{"blob" => String.duplicate("x", n)} is n + 11 bytes.
      at_limit = %{"blob" => String.duplicate("x", 8181)}
      over_limit = %{"blob" => String.duplicate("x", 8182)}

      assert byte_size(Patchbay.Patchbay.CanonicalJSON.encode(at_limit)) == 8192

      assert %{} = report!(tool, %{observed: at_limit})

      assert {:error, error} =
               Forum.file_report(report_attrs(tool, %{observed: over_limit}))

      assert Exception.message(error) =~ "observed"

      assert {:error, error} =
               Forum.file_report(report_attrs(tool, %{handler_result: over_limit}))

      assert Exception.message(error) =~ "handler_result"
    end

    test "lists reports newest first with replies loadable" do
      tool = tool!(site!())
      older = report!(tool, %{note: "older"})
      newer = report!(tool, %{note: "newer"})

      Forum.add_reply!(reply_attrs(older, %{note: "seen it too"}))

      assert [first, second] =
               results(Forum.list_reports_for_tools!([tool.id], load: [:replies]))

      assert first.id == newer.id
      assert second.id == older.id
      assert first.replies == []
      assert [%{note: "seen it too"}] = second.replies
    end
  end

  describe "add_reply/1" do
    test "lists replies oldest first" do
      report = report!(tool!(site!()))

      Forum.add_reply!(reply_attrs(report, %{verdict: :verified_failure, note: "reproduced"}))
      Forum.add_reply!(reply_attrs(report, %{verdict: :verified_success, note: "fixed now"}))

      assert [%{note: "reproduced"}, %{note: "fixed now"}] =
               results(Forum.list_replies_for_report!(report.id))
    end

    test "never accepts owner_response from a caller" do
      report = report!(tool!(site!()))

      assert {:error, error} = Forum.add_reply(reply_attrs(report, %{owner_response: true}))
      assert Exception.message(error) =~ "No such input `owner_response`"

      refute :owner_response in Ash.Resource.Info.action(Reply, :add_reply).accept
      refute Forum.add_reply!(reply_attrs(report, %{})).owner_response
    end

    test "rejects a note longer than 500 bytes and strips control characters" do
      report = report!(tool!(site!()))

      assert {:error, error} =
               Forum.add_reply(reply_attrs(report, %{note: String.duplicate("é", 251)}))

      assert Exception.message(error) =~ "500 bytes"

      assert %{note: "ab"} = Forum.add_reply!(reply_attrs(report, %{note: "a\u0000b"}))
    end
  end

  describe "add_operator_reply/1" do
    test "is out of reach of anything that comes in from outside" do
      report = report!(tool!(site!()))

      assert {:error, error} =
               Forum.add_operator_reply(%{
                 report_id: report.id,
                 verdict: :unknown,
                 note: "posing as the site"
               })

      assert Exception.message(error) =~ "orbidden"
    end

    test "posts as Patchbay itself, and no caller can say otherwise" do
      report = report!(tool!(site!()))

      reply =
        Forum.add_operator_reply!(
          %{
            report_id: report.id,
            verdict: :verified_failure,
            note: "We have replaced the tool."
          },
          authorize?: false
        )

      assert reply.owner_response
      assert reply.browser_session_id == Patchbay.Config.agent_session_id()
      assert reply.note == "We have replaced the tool."

      accepted = Ash.Resource.Info.action(Reply, :add_operator_reply).accept
      refute :owner_response in accepted
      refute :browser_session_id in accepted
    end
  end

  describe "tool aggregates" do
    test "count reports, distinct sessions, verdicts and recency" do
      tool = tool!(site!())
      session_one = Ash.UUID.generate()
      session_two = Ash.UUID.generate()

      report!(tool, %{browser_session_id: session_one, verdict: :verified_success})
      report!(tool, %{browser_session_id: session_one, verdict: :errored})
      latest = report!(tool, %{browser_session_id: session_two, verdict: :verified_failure})

      assert [loaded] =
               results(
                 Forum.list_tools_for_site!(tool.site_id,
                   load: [
                     :report_count,
                     :distinct_session_count,
                     :verified_success_count,
                     :verified_failure_count,
                     :errored_count,
                     :unknown_count,
                     :latest_report_at
                   ]
                 )
               )

      assert loaded.report_count == 3
      assert loaded.distinct_session_count == 2
      assert loaded.verified_success_count == 1
      assert loaded.verified_failure_count == 1
      assert loaded.errored_count == 1
      assert loaded.unknown_count == 0
      assert DateTime.compare(loaded.latest_report_at, latest.inserted_at) == :eq
    end
  end
end
