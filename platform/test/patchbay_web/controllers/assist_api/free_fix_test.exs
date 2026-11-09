defmodule PatchbayWeb.AssistAPI.FreeFixTest do
  @moduledoc """
  A free fix through the agent door: it opens for the signed agent alone and
  reads back for it alone; every request Patchbay would not act on is refused
  before a run opens; one assist at a time for each agent; two free fixes in
  any 24 hours for each wallet, and none once the site has given its day's
  worth. An assist paid for before paid assists ended still reads back for
  its payer.
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.AssistFixtures, only: [paid_run: 2]

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Assist.Run
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent

  @args %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "sign_in" => "unknown",
    "believed_calls" => [%{"tool" => " reserve_table ", "arguments" => %{"party" => 2}}]
  }

  setup do
    SignedAgent.stub_siwa()
    %{agent: SignedAgent.pair!(), other: SignedAgent.pair!()}
  end

  test "a free fix opens for the agent that asked, and reads back for it alone", c do
    opened = ask(c.agent, @args) |> json_response(202)

    run_id = opened["run_id"]
    assert opened["status"] == "paid"
    assert opened["payment_intent_id"] == nil
    assert opened["fee_deposit"]["status"] == "no_fee"
    assert opened["assist_url"] == url(~p"/api/agent/assists/#{run_id}")
    assert opened["next_action"] =~ "free fix"

    run = c.agent |> read(run_id) |> json_response(200)
    assert run["goal"] == @args["goal"]
    assert run["site_url"] == @args["site_url"]
    assert run["sign_in"] == "unknown"
    assert run["believed_calls"] == [%{"tool" => "reserve_table", "arguments" => %{"party" => 2}}]
    assert run["steps"] == []

    # Another agent cannot tell the run from one that never existed.
    hidden = c.other |> read(run_id) |> json_response(404)
    absent = c.other |> read(Ecto.UUID.generate()) |> json_response(404)
    assert hidden == absent
    assert hidden["error"]["code"] == "not_found"
  end

  test "requests Patchbay would not act on are refused before a run opens", c do
    refused = ask(c.agent, Map.put(@args, "sign_in", "required")) |> json_response(422)
    assert refused["error"]["code"] == "needs_sign_in"

    for {bad, words} <- [
          {Map.put(@args, "site_url", "http://bookings.example.com"), "site_url"},
          {Map.put(@args, "site_url", "https://10.0.0.1/app"), "site_url"},
          {Map.put(@args, "site_url", "https://[::1]/app"), "site_url"},
          {Map.put(@args, "site_url", "https://localhost/app"), "site_url"},
          {Map.put(@args, "site_url", "https://localhost./app"), "site_url"},
          {Map.put(@args, "site_url", "https://vault.internal./app"), "site_url"},
          {Map.put(@args, "site_url", "https://vault.interna%6C/app"), "site_url"},
          {Map.put(@args, "site_url", "https://bookings.example.com:6379/app"), "site_url"},
          {Map.put(@args, "site_url", "https://bookings.example.test/app"), "site_url"},
          {Map.put(
             @args,
             "site_url",
             "https://bookings.example.com/" <> String.duplicate("a", 2_048)
           ), "site_url"},
          {Map.put(
             @args,
             "site_url",
             "https://" <> String.duplicate("a", 250) <> ".example.com/"
           ), "site_url"},
          {Map.put(@args, "site_url", "https://intranet"), "site_url"},
          {Map.put(@args, "site_url", "https://vault.internal/app"), "site_url"},
          {Map.put(@args, "site_url", "https://user:pw@bookings.example.com"), "site_url"},
          {Map.put(@args, "goal", String.duplicate("x", 1_001)), "goal"},
          {Map.put(@args, "goal", "   "), "goal"},
          {Map.delete(@args, "goal"), "goal"},
          {Map.put(@args, "sign_in", "maybe"), "sign_in"},
          {Map.put(@args, "believed_calls", List.duplicate(%{"tool" => "t"}, 6)),
           "believed_calls"},
          {Map.put(@args, "believed_calls", [%{"tool" => "t", "extra" => 1}]), "believed_calls"},
          {Map.put(@args, "believed_calls", [%{"arguments" => %{}}]), "believed_calls"},
          {Map.put(@args, "believed_calls", [%{"tool" => "t", "arguments" => "no"}]),
           "believed_calls"},
          {Map.put(@args, "amount_usdc", "0.10"), "amount_usdc"}
        ] do
      body = ask(c.agent, bad) |> json_response(422)
      assert body["error"]["code"] == "invalid"
      assert [message] = body["error"]["details"]
      assert String.starts_with?(message, words <> ":")
    end

    # Nothing opened, so both of the day's free fixes are still there.
    assert {:ok, :agent} = Allowance.agent_grant(profile(c.agent))
    opened = ask(c.agent, @args) |> json_response(202)
    close(opened["run_id"])
    assert ask(c.agent, @args) |> json_response(202)
  end

  test "one assist at a time: a second ask while one is open is refused with the first", c do
    opened = ask(c.agent, @args) |> json_response(202)

    refused = ask(c.agent, @args) |> json_response(409)
    assert refused["error"]["code"] == "assist_running"
    assert refused["error"]["run_id"] == opened["run_id"]
    assert refused["error"]["assist_url"] == opened["assist_url"]

    # Another agent is not held up by it.
    assert ask(c.other, @args) |> json_response(202)
  end

  test "two free fixes in any 24 hours, and none once the site has given its day's worth", c do
    for _ <- 1..2 do
      opened = ask(c.agent, @args) |> json_response(202)
      close(opened["run_id"])
    end

    used = ask(c.agent, @args) |> json_response(429)
    assert used["error"]["code"] == "free_fixes_used"

    old = Application.get_env(:patchbay, :daily_free_fixes)
    on_exit(fn -> restore(:daily_free_fixes, old) end)
    Application.put_env(:patchbay, :daily_free_fixes, 2)

    given_out = ask(c.other, @args) |> json_response(429)
    assert given_out["error"]["code"] == "free_fixes_given_out"
  end

  test "a wallet whose free fixes are used is told when the next comes back", c do
    [older, _newer] =
      for _ <- 1..2 do
        opened = ask(c.agent, @args) |> json_response(202)
        close(opened["run_id"])
        opened["run_id"]
      end

    # The older was asked for 23 hours ago, so it comes back in an hour.
    Patchbay.Repo.query!("UPDATE assist_runs SET inserted_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -23 * 60 * 60, :second),
      Ecto.UUID.dump!(older)
    ])

    refused = ask(c.agent, @args)
    used = json_response(refused, 429)
    assert used["error"]["code"] == "free_fixes_used"
    assert used["error"]["retry_after_seconds"] in (60 * 60 - 60)..(60 * 60)
    assert get_resp_header(refused, "retry-after") == ["#{used["error"]["retry_after_seconds"]}"]
  end

  test "an assist paid for before paid assists ended reads back for its payer alone" do
    payer = person()
    run = paid_run(payer, "0x" <> String.duplicate("d", 40))

    read = payer |> signed_in() |> get(~p"/api/assists/#{run.id}") |> json_response(200)
    assert read["status"] == "paid"
    assert read["payment_intent_id"] == run.payment_intent_id
    assert read["fee_deposit"]["status"] == "pending"
    assert read["next_action"] =~ "Do not pay again"

    stranger = person()
    hidden = stranger |> signed_in() |> get(~p"/api/assists/#{run.id}") |> json_response(404)

    absent =
      stranger
      |> signed_in()
      |> get(~p"/api/assists/#{Ecto.UUID.generate()}")
      |> json_response(404)

    assert hidden == absent
  end

  defp ask(agent, args),
    do:
      build_conn()
      |> SignedAgent.sign(agent)
      |> post(~p"/api/agent/assists", Jason.encode!(%{args: args}))

  defp read(agent, id),
    do: build_conn() |> SignedAgent.sign(agent) |> get(~p"/api/agent/assists/#{id}")

  # Closing a run the way Patchbay's own worker does, so the next may open.
  defp close(run_id) do
    run = Ash.get!(Run, run_id, authorize?: false)
    {:ok, running} = Assist.start_run(run, authorize?: false)

    {:ok, _done} =
      Assist.finish_run(running, %{status: :finished, outcome: :not_possible}, authorize?: false)
  end

  defp restore(setting, nil), do: Application.delete_env(:patchbay, setting)
  defp restore(setting, value), do: Application.put_env(:patchbay, setting, value)

  defp profile(%{wallet: wallet}), do: Identity.upsert_from_wallet!(%{wallet_address: wallet})

  defp signed_in(profile),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(profile.id)

  defp person,
    do:
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:assist-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      })
end
