defmodule PatchbayWeb.PaymentsAPI.CreditBountyTest do
  @moduledoc """
  A priority report paid from Patchbay Credits: the report is published in the
  same step as the spend, with its bounty held on Patchbay's own ledger and
  never sent to Base. Accepting an answer pays its author 90% in credits at
  once; after thirty days with no answer accepted the asker can take 90% back.
  Either happens once, never both.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.PaymentsAPI.Purchase
  alias PatchbayWeb.Plugs.CurrentProfile

  @escrow "0x" <> String.duplicate("e", 40)

  setup do
    old_escrow = Application.get_env(:patchbay, :escrow)
    Application.put_env(:patchbay, :escrow, contract_address: @escrow)
    on_exit(fn -> Application.put_env(:patchbay, :escrow, old_escrow) end)

    asker = profile("a")

    {:ok, :credited} =
      Credits.record_card_purchase(asker.id, 1_000, "pi_" <> Ecto.UUID.generate())

    %{asker: asker, origin: "https://credits-#{Ecto.UUID.generate()}.invalid"}
  end

  test "a report paid from credits is published with its bounty held in credits",
       %{asker: asker} = c do
    prepared = prepare(asker, c.origin, "5.00")
    applied = pay_from_credits(asker, prepared)

    assert get_resp_header(applied, "payment-response") == []
    applied = json_response(applied, 200)
    assert applied["status"] == "applied"
    assert applied["paid_with"] == "patchbay_credits"
    assert Credits.balance_atomic(asker.id) == 5_000_000

    report = Forum.get_report!(applied["report_id"])
    assert report.bounty_paid_with == :credits
    assert report.escrow_status == :credited
    assert report.escrow_funded_at
    assert is_nil(report.escrow_credit_tx_hash)

    # Base never hears of it, so the watch never asks Base about it.
    refute report.id in Enum.map(Forum.bounties_to_reconcile!(), & &1.id)

    read =
      asker
      |> signed_in()
      |> get(~p"/api/payment_intents/#{prepared["id"]}")
      |> json_response(200)

    assert read["result"]["bounty_paid_with"] == "patchbay_credits"
    assert read["result"]["credit_confirmation"] == "confirmed"
    assert read["result"]["next_action"] =~ "held in Patchbay Credits"
    refute read["result"]["next_action"] =~ "Base"

    # Asking again pays nothing more and publishes nothing more.
    again = asker |> pay_from_credits(prepared) |> json_response(200)
    assert again["status"] == "applied"
    assert Credits.balance_atomic(asker.id) == 5_000_000

    page = build_conn() |> get(~p"/reports/#{report.id}") |> html_response(200)
    assert page =~ "5.00 Patchbay Credits on this report"
    assert page =~ "Held by Patchbay until the asker accepts an answer"
    refute page =~ "checked onchain"
  end

  test "a balance that does not cover the bounty publishes nothing", %{asker: asker} = c do
    prepared = prepare(asker, c.origin, "20.00")

    short = asker |> pay_from_credits(prepared) |> json_response(402)
    assert short["problem_code"] == "credits_short"
    assert short["balance_credits"] == "10.00"

    assert {:ok, nil} = Forum.get_report(prepared["report_id"], not_found_error?: false)
    assert Credits.balance_atomic(asker.id) == 10_000_000
  end

  test "accepting an answer pays its author 90% in credits at once, and only once",
       %{asker: asker} = c do
    report = paid_report(asker, c.origin)
    author = profile("b")
    reply = reply(report, author)

    accepted =
      asker
      |> signed_in()
      |> post(~p"/forum/reports/#{report.id}/accept", %{reply_id: reply.id})
      |> json_response(200)

    assert accepted["escrow_status"] == "released"
    assert accepted["bounty_paid_with"] == "patchbay_credits"
    assert is_nil(accepted["release_tx_hash"])
    assert Credits.balance_atomic(author.id) == 4_500_000
    assert Credits.balance_atomic(asker.id) == 5_000_000

    again =
      asker
      |> signed_in()
      |> post(~p"/forum/reports/#{report.id}/accept", %{reply_id: reply.id})
      |> json_response(422)

    assert again["problem_code"] == "invalid"
    assert Credits.balance_atomic(author.id) == 4_500_000

    # Nor can the asker take back what an answer has won, even after thirty days.
    held_since(report, 31)
    refused = asker |> signed_in() |> post(~p"/forum/reports/#{report.id}/refund")

    assert json_response(refused, 422)["errors"] == [
             "report_id: An answer was accepted, so this bounty has gone to its author."
           ]

    assert Credits.balance_atomic(asker.id) == 5_000_000

    assert [%{what: :bounty_award, paid_in: :credits, amount_atomic: 4_500_000}] =
             Patchbay.Payments.payment_history(author)

    history = author |> signed_in() |> get(~p"/agents/#{author.public_id}") |> html_response(200)
    assert history =~ "Bounty won for an accepted answer"
  end

  test "a bounty won by an agent paired with a person is paid onto their shared balance",
       %{asker: asker} = c do
    report = paid_report(asker, c.origin)
    person = profile("c")
    agent = Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("d", 40)})
    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)
    reply = reply(report, agent)

    asker
    |> signed_in()
    |> post(~p"/forum/reports/#{report.id}/accept", %{reply_id: reply.id})
    |> json_response(200)

    assert Credits.balance_atomic(person.id) == 4_500_000
    assert Credits.balance_atomic(agent.id) == 4_500_000

    assert [%{what: :bounty_award, amount_atomic: 4_500_000}] =
             Patchbay.Payments.payment_history(person)
  end

  test "a bounty taken back goes to the balance that paid for it, not to whoever the agent is paired with now",
       c do
    person = profile("c")

    {:ok, :credited} =
      Credits.record_card_purchase(person.id, 1_000, "pi_" <> Ecto.UUID.generate())

    agent = Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("d", 40)})
    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)

    # The agent's report is paid from the person's balance, through the same
    # purchase every door runs.
    {:ok, found} =
      Purchase.special_post_on_offer(agent, %{
        "origin" => c.origin,
        "tool_name" => "checkout",
        "verdict" => "verified_failure",
        "note" => "The cart never changed.",
        "amount_usdc" => "5.00"
      })

    request = %{payment: :credits, payer: agent.wallet_address, browser_session_id: nil}
    assert {:applied, applied, _receipt} = Purchase.execute(agent, found.id, request)
    report = Forum.get_report!(applied.target_id)
    assert Credits.balance_atomic(person.id) == 5_000_000

    # The person unpairs it, and another person pairs it.
    {:ok, _unpaired} = Pairing.unpair(person, agent.public_id)
    other = profile("f")
    {:ok, %{code: other_code}} = Pairing.issue(other)
    {:ok, _other} = Pairing.pair(agent, other_code)

    held_since(report, 31)
    assert {:ok, _returned} = PriorityRefund.run(report.id, agent)

    assert Credits.balance_atomic(person.id) == 9_500_000
    assert Credits.balance_atomic(other.id) == 0
  end

  test "the asker takes 90% back in credits after thirty days, and only once",
       %{asker: asker} = c do
    report = paid_report(asker, c.origin)

    early = asker |> signed_in() |> post(~p"/forum/reports/#{report.id}/refund")
    assert [early_said] = json_response(early, 422)["errors"]
    assert early_said =~ "This bounty can be taken back from"
    assert early_said =~ "Nothing has moved."
    assert Credits.balance_atomic(asker.id) == 5_000_000
    assert Forum.get_report!(report.id).escrow_status == :credited

    held_since(report, 31)

    returned =
      asker
      |> signed_in()
      |> post(~p"/forum/reports/#{report.id}/refund")
      |> json_response(200)

    assert returned["escrow_status"] == "refunded"
    assert returned["bounty_paid_with"] == "patchbay_credits"
    assert Credits.balance_atomic(asker.id) == 9_500_000

    again = asker |> signed_in() |> post(~p"/forum/reports/#{report.id}/refund")

    assert json_response(again, 422)["errors"] == [
             "report_id: This bounty has already gone back to its asker."
           ]

    assert Credits.balance_atomic(asker.id) == 9_500_000

    # A bounty taken back has nothing left to award.
    reply = reply(report, profile("c"))

    asker
    |> signed_in()
    |> post(~p"/forum/reports/#{report.id}/accept", %{reply_id: reply.id})
    |> json_response(422)

    page = build_conn() |> get(~p"/reports/#{report.id}") |> html_response(200)
    assert page =~ "90% of it went back to the asker&#39;s Patchbay Credits"
  end

  test "the page's take-back button says the bounty goes back to credits", %{asker: asker} = c do
    report = paid_report(asker, c.origin)

    page = asker |> signed_in() |> get(~p"/reports/#{report.id}") |> html_response(200)
    assert page =~ "back to your Patchbay Credits"
    assert page =~ "The asker can take this bounty back from"

    pressed =
      asker
      |> signed_in()
      |> post(~p"/reports/#{report.id}/refund", %{})
      |> html_response(200)

    assert pressed =~ "This bounty can be taken back from"
    refute pressed =~ "Base would not take that request"

    held_since(report, 31)

    taken_back = asker |> signed_in() |> post(~p"/reports/#{report.id}/refund", %{})
    assert redirected_to(taken_back) == ~p"/reports/#{report.id}" <> "#patchbay-escrow"
    assert Credits.balance_atomic(asker.id) == 9_500_000
  end

  defp paid_report(asker, origin) do
    prepared = prepare(asker, origin, "5.00")
    %{"report_id" => id} = asker |> pay_from_credits(prepared) |> json_response(200)
    Forum.get_report!(id)
  end

  # How long ago the bounty was held; the clock is the only thing a test
  # cannot wait thirty days for.
  defp held_since(report, days) do
    report
    |> Ecto.Changeset.change(escrow_funded_at: DateTime.add(DateTime.utc_now(), -days, :day))
    |> Patchbay.Repo.update!()
  end

  defp reply(report, author) do
    Forum.add_human_reply!(
      %{
        report_id: report.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :verified_success,
        note: "Send the cart id with the request."
      },
      actor: author
    )
  end

  defp prepare(asker, origin, amount) do
    asker
    |> signed_in()
    |> post(~p"/api/payment_intents", %{
      kind: "special_post",
      args: %{
        origin: origin,
        tool_name: "checkout",
        verdict: "verified_failure",
        note: "The cart never changed.",
        amount_usdc: amount
      }
    })
    |> json_response(201)
  end

  defp pay_from_credits(asker, prepared) do
    asker |> signed_in() |> post(prepared["execute_url"], %{"pay_with" => "credits"})
  end

  defp profile(letter) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:credit-bounty-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate(letter, 40)
    })
  end

  defp signed_in(profile) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end
end
