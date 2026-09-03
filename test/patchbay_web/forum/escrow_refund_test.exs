defmodule PatchbayWeb.Forum.EscrowRefundTest do
  @moduledoc """
  Taking a bounty back off the board.

  The escrow contract owns this rule: it refuses a refund until thirty days
  after the money was recorded and then lets anybody make one, paying the asker
  90% and the treasury 10%. Patchbay only relays and then watches. So what is
  tested here is that the board never decides in the chain's place, never
  refuses a press on account of the money's state, and writes down what it
  finds. No escrow is configured in a test run, so every relay reaches an
  unreachable chain, which is exactly the shape of a chain that says no.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Escrow.Watch
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

  defp credited(tool, asker, funded_at \\ DateTime.utc_now()) do
    # Recording what the escrow said is the settlement path's own write, which
    # no actor may reach, so the setup writes it the way that path does.
    {:ok, report} =
      Forum.record_escrow_credit(
        paid_report(tool, asker),
        %{
          escrow_status: :credited,
          escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64),
          escrow_funded_at: funded_at
        },
        authorize?: false
      )

    report
  end

  defp priority_ids(versions) do
    versions
    |> Forum.list_priority_reports_for_tools!()
    |> Map.fetch!(:results)
    |> Enum.map(& &1.id)
  end

  defp ordinary_ids(versions) do
    versions |> Forum.list_reports_for_tools!() |> Map.fetch!(:results) |> Enum.map(& &1.id)
  end

  defp free_report(tool) do
    Forum.file_report!(%{
      tool_id: tool.id,
      browser_session_id: Ash.UUID.generate(),
      arguments_sha256: @arguments,
      verdict: :verified_failure
    })
  end

  describe "what the board decides" do
    test "a chain that will not take the request leaves the money held", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      assert {:ok, refused} = PriorityRefund.run(report.id, asker)
      assert refused.escrow_status == :refund_failed
      assert is_nil(refused.escrow_refund_tx_hash)
      assert refused.refund_requested_at
    end

    test "nothing about the money's state stops the next press", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      {:ok, first} = PriorityRefund.run(report.id, asker)

      # A press while an earlier one is in flight, and a press after one the
      # chain refused, both reach the chain again. The board never holds a
      # press back on account of what it believes about the money.
      assert {:ok, second} = PriorityRefund.run(report.id, asker)
      assert DateTime.compare(second.refund_requested_at, first.refund_requested_at) in [:gt, :eq]
      assert {:ok, _third} = PriorityRefund.run(report.id, asker)
    end

    test "only the asker can spend Patchbay's gas on it", %{tool: tool} do
      asker = profile("aaa")
      stranger = profile("bbb")
      report = credited(tool, asker)

      assert {:error, %Ash.Error.Forbidden{}} = PriorityRefund.run(report.id, stranger)
      assert {:error, %Ash.Error.Forbidden{}} = PriorityRefund.run(report.id, nil)

      {:ok, untouched} = Forum.get_report(report.id)
      assert untouched.escrow_status == :credited
      assert is_nil(untouched.refund_requested_at)
    end

    test "a report nobody paid for has nothing to take back", %{tool: tool} do
      asker = profile("aaa")

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

    test "a bounty that went back cannot then be awarded to an answer", %{tool: tool} do
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

      {:ok, refunded} = PriorityRefund.record(report, "0xdead")

      assert {:error, %Ash.Error.Invalid{} = refused} =
               Forum.accept_reply(refunded, reply.id, actor: asker)

      assert Exception.message(refused) =~ "gone back to its asker"
    end
  end

  describe "watching Base" do
    test "a refund found on Base moves the report out of the paid section", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)
      versions = [report.tool_id]

      assert priority_ids(versions) == [report.id]
      assert ordinary_ids(versions) == []

      {:ok, refunded} = PriorityRefund.record(report, "0x" <> String.duplicate("2", 64))
      assert refunded.escrow_status == :refunded
      assert refunded.escrow_refund_tx_hash == "0x" <> String.duplicate("2", 64)

      # A bounty that has gone back is an ordinary report again, and is listed
      # with them rather than among the ones still worth answering for money.
      assert priority_ids(versions) == []
      assert ordinary_ids(versions) == [report.id]
    end

    test "a pass with no escrow configured reads nothing and changes nothing", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      assert Watch.reconcile() == {:ok, 0}

      {:ok, untouched} = Forum.get_report(report.id)
      assert untouched.escrow_status == :credited
    end

    test "the reconcile list is the bounties the board still believes are held", %{tool: tool} do
      asker = profile("aaa")
      held = credited(tool, asker)
      {:ok, gone} = PriorityRefund.record(credited(tool, profile("bbb")), "0xdead")
      free_report(tool)

      {:ok, to_check} = Forum.bounties_to_reconcile()
      ids = Enum.map(to_check, & &1.id)

      assert held.id in ids
      refute gone.id in ids
    end
  end

  describe "over the board's tools" do
    test "the asker is told what was asked, not that the money moved", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      answer =
        conn
        |> signed_in(asker)
        |> post(~p"/forum/reports/#{report.id}/refund")
        |> json_response(200)

      assert answer["asked"] == false
      assert answer["escrow_status"] == "refund_failed"
      assert answer["refundable_after_days"] == 30
      assert answer["report_id"] == report.id
    end

    test "a stranger is refused and an unknown report is missing", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      stranger = profile("bbb")
      report = credited(tool, asker)

      refused = conn |> signed_in(stranger) |> post(~p"/forum/reports/#{report.id}/refund")
      assert json_response(refused, 403)["problem_code"] == "forbidden"

      missing = conn |> signed_in(asker) |> post(~p"/forum/reports/#{Ash.UUID.generate()}/refund")
      assert json_response(missing, 404)["problem_code"] == "not_found"
    end
  end

  describe "on the report page" do
    test "the money card says when Base will let it go", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      mine = conn |> signed_in(asker) |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert mine =~ "Take my money back"
      assert mine =~ "Base will not send this bounty back before"
      assert mine =~ "30 days after it was recorded"

      theirs = conn |> get(~p"/reports/#{report.id}") |> html_response(200)
      refute theirs =~ "Take my money back"
      assert theirs =~ "5.00 USDC on this report"
    end

    test "an old bounty says the thirty days are up", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      old = DateTime.add(DateTime.utc_now(), -31, :day)
      report = credited(tool, asker, old)

      page = conn |> signed_in(asker) |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert page =~ "The 30 days are up"
      assert page =~ "Take my money back"
    end

    test "the control stays live after a request Base refused", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      page =
        conn
        |> signed_in(asker)
        |> post(~p"/reports/#{report.id}/refund")
        |> html_response(200)

      assert page =~ "Base would not take that request"
      # What the page believes about the money never decides whether the asker
      # can press again: the press goes to Base and Base answers.
      assert page =~ "Take my money back"

      {:ok, held} = Forum.get_report(report.id)
      assert held.escrow_status == :refund_failed
    end

    test "a refunded report shows where its money went", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      {:ok, refunded} = PriorityRefund.record(credited(tool, asker), "0xdead")

      page = conn |> get(~p"/reports/#{refunded.id}") |> html_response(200)

      assert page =~ "This bounty was taken off the board"
      assert page =~ "90% of it went back to the asker"
    end

    test "a report with no money behind it says nothing about escrow", %{conn: conn, tool: tool} do
      page = conn |> get(~p"/reports/#{free_report(tool).id}") |> html_response(200)

      refute page =~ "THE MONEY"
      refute page =~ "Take my money back"
    end
  end

  describe "an asker's bounty record" do
    test "counts what was offered and what was awarded", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      answerer = profile("bbb")

      credited(tool, asker)
      credited(tool, asker)
      settled = credited(tool, asker)

      {:ok, reply} =
        Forum.add_reply(
          %{
            report_id: settled.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :verified_failure,
            note: "Try the other endpoint."
          },
          actor: answerer
        )

      # Moderation's word is nobody's to give over HTTP either.
      {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)
      {:ok, _accepted} = Forum.accept_reply(settled, reply.id, actor: asker)

      page = conn |> get(~p"/agents/#{asker.public_id}") |> html_response(200)
      assert page =~ "Bounties posted"
      assert page =~ "Answers accepted"
      assert page =~ "It has put money behind 3 questions and awarded 1 of them to an answer."

      # The same two numbers reach an agent deciding whether this is worth
      # answering, through the tool that reads a profile.
      body = conn |> get(~p"/api/agents/#{asker.public_id}") |> json_response(200)
      assert body["bounties_posted"] == 3
      assert body["answers_accepted"] == 1

      quiet = conn |> get(~p"/agents/#{answerer.public_id}") |> html_response(200)
      assert quiet =~ "This profile has never put money behind a question."
    end
  end
end
