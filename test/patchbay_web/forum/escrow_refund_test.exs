defmodule PatchbayWeb.Forum.EscrowRefundTest do
  @moduledoc """
  Taking back the money behind a paid priority report: who may, when the board
  refuses, and what the asker sees on the page.

  No escrow is configured in a test run, so every attempt that gets past the
  board reaches an unreachable chain and comes back refused. That is the point
  of the shape being tested: what the board allows and what the chain decides
  are two separate answers, and the money is only ever written as moved when
  the chain says so.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  @contract String.duplicate("e", 64)
  @arguments String.duplicate("f", 64)

  setup do
    site = Forum.register_site!("shop.example.com")
    tool = Forum.observe_tool!(%{site_id: site.id, name: "checkout", contract_sha256: @contract})

    %{site: site, tool: tool}
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

  defp paid_report(tool, asker) do
    Forum.file_priority_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: "The cart never changed.",
        priority_amount_atomic: 5_000_000,
        payment_intent_id: Ash.UUID.generate()
      },
      actor: asker
    )
  end

  defp credited(tool, asker) do
    # Recording what the escrow said is the settlement path's own write, which
    # no actor may reach, so the setup writes it the way that path does.
    {:ok, report} =
      Forum.record_escrow_credit(
        paid_report(tool, asker),
        %{escrow_status: :credited, escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64)},
        authorize?: false
      )

    report
  end

  defp free_report(tool) do
    Forum.file_report!(%{
      tool_id: tool.id,
      browser_session_id: Ash.UUID.generate(),
      arguments_sha256: @arguments,
      verdict: :verified_failure
    })
  end

  test "an unreachable chain leaves the money held and says so", %{tool: tool} do
    asker = profile("aaa")
    report = credited(tool, asker)

    assert {:ok, after_first} = PriorityRefund.run(report.id, asker)
    assert after_first.escrow_status == :refund_failed
    assert is_nil(after_first.escrow_refund_tx_hash)

    # Nothing moved, so the asker is not locked out of trying again.
    assert {:ok, after_second} = PriorityRefund.run(report.id, asker)
    assert after_second.escrow_status == :refund_failed
  end

  test "only the person who put the money up can take it back", %{tool: tool} do
    asker = profile("aaa")
    stranger = profile("bbb")
    report = credited(tool, asker)

    assert {:error, %Ash.Error.Forbidden{}} = PriorityRefund.run(report.id, stranger)
    assert {:error, %Ash.Error.Forbidden{}} = PriorityRefund.run(report.id, nil)

    {:ok, untouched} = Forum.get_report(report.id)
    assert untouched.escrow_status == :credited
  end

  test "a report nobody paid for has nothing to take back", %{tool: tool} do
    asker = profile("aaa")
    report = free_report(tool)

    # A free report has no author, so nobody can reach it; the one that has an
    # author and no money is the case the board has to answer for.
    assert {:error, _forbidden} = PriorityRefund.run(report.id, asker)

    unpaid =
      Forum.file_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_failure
        },
        actor: asker
      )

    assert {:error, %Ash.Error.Invalid{} = refused} = PriorityRefund.run(unpaid.id, asker)
    assert Exception.message(refused) =~ "no money behind it"
  end

  test "money already on its way back cannot be sent again", %{tool: tool} do
    asker = profile("aaa")
    report = credited(tool, asker)

    {:ok, marked} = Forum.withdraw_priority_report(report, actor: asker)
    assert marked.escrow_status == :refunding

    assert {:error, %Ash.Error.Invalid{} = refused} =
             Forum.withdraw_priority_report(marked, actor: asker)

    assert Exception.message(refused) =~ "already on its way back"
  end

  test "an awarded answer settles the money for good", %{tool: tool} do
    asker = profile("aaa")
    answerer = profile("bbb")
    report = credited(tool, asker)

    {:ok, reply} =
      Forum.add_reply(
        %{
          report_id: report.id,
          browser_session_id: Ash.UUID.generate(),
          verdict: :verified_failure,
          note: "Same here."
        },
        actor: answerer
      )

    # Moderation's word is nobody's to give over HTTP either.
    {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)

    {:ok, accepted} = Forum.accept_reply(report, reply.id, actor: asker)

    assert {:error, %Ash.Error.Invalid{} = refused} = PriorityRefund.run(accepted.id, asker)
    assert Exception.message(refused) =~ "already been awarded"
  end

  test "money taken back cannot then be awarded to an answer", %{tool: tool} do
    asker = profile("aaa")
    answerer = profile("bbb")
    report = credited(tool, asker)

    {:ok, reply} =
      Forum.add_reply(
        %{
          report_id: report.id,
          browser_session_id: Ash.UUID.generate(),
          verdict: :verified_failure,
          note: "Same here."
        },
        actor: answerer
      )

    # Moderation's word is nobody's to give over HTTP either.
    {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)

    {:ok, withdrawn} = Forum.withdraw_priority_report(report, actor: asker)

    assert {:error, %Ash.Error.Invalid{} = refused} =
             Forum.accept_reply(withdrawn, reply.id, actor: asker)

    assert Exception.message(refused) =~ "gone back to its asker"
  end

  describe "over the board's tools" do
    test "the asker is told what the chain did", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      answer =
        conn
        |> signed_in(asker)
        |> post(~p"/forum/reports/#{report.id}/refund")
        |> json_response(200)

      assert answer["withdrawn"] == false
      assert answer["escrow_status"] == "refund_failed"
      assert answer["report_id"] == report.id
    end

    test "a stranger is refused and an unknown report is missing", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      stranger = profile("bbb")
      report = credited(tool, asker)

      refused =
        conn |> signed_in(stranger) |> post(~p"/forum/reports/#{report.id}/refund")

      assert json_response(refused, 403)["problem_code"] == "forbidden"

      missing =
        conn |> signed_in(asker) |> post(~p"/forum/reports/#{Ash.UUID.generate()}/refund")

      assert json_response(missing, 404)["problem_code"] == "not_found"
    end
  end

  describe "on the report page" do
    test "the asker gets a live control and a visitor gets none", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      stranger = profile("bbb")
      report = credited(tool, asker)

      mine =
        conn |> signed_in(asker) |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert mine =~ "Take my money back"
      assert mine =~ "Held on Base until the asker accepts an answer"

      theirs =
        conn |> signed_in(stranger) |> get(~p"/reports/#{report.id}") |> html_response(200)

      refute theirs =~ "Take my money back"
      assert theirs =~ "5.00 USDC on this report"

      signed_out = conn |> get(~p"/reports/#{report.id}") |> html_response(200)
      refute signed_out =~ "Take my money back"
    end

    test "the control stays live while an earlier ask is in flight", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)
      {:ok, in_flight} = Forum.withdraw_priority_report(report, actor: asker)

      page =
        conn |> signed_in(asker) |> get(~p"/reports/#{in_flight.id}") |> html_response(200)

      # What the page believes about the money never decides whether the asker
      # can press: the press goes to Base and Base answers.
      assert page =~ "Take my money back"
      assert page =~ "on its way back to them"
    end

    test "pressing it says what happened without leaving the report", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      page =
        conn
        |> signed_in(asker)
        |> post(~p"/reports/#{report.id}/refund")
        |> html_response(200)

      assert page =~ "Base did not take that request"
      assert page =~ "Take my money back"

      {:ok, held} = Forum.get_report(report.id)
      assert held.escrow_status == :refund_failed
    end

    test "a report with no money behind it says nothing about escrow", %{conn: conn, tool: tool} do
      page = conn |> get(~p"/reports/#{free_report(tool).id}") |> html_response(200)

      refute page =~ "THE MONEY"
      refute page =~ "Take my money back"
    end
  end
end
