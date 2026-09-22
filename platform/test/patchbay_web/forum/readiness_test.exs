defmodule PatchbayWeb.Forum.ReadinessTest do
  @moduledoc """
  Readiness says only what the server verified: the session the cookie names,
  the profile the session signed in, the wallet Privy verified, the USDC the
  chain reports, and that cards are not offered. Nothing here signs or spends,
  and a caller cannot name a wallet of its own to have read.
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  alias PatchbayWeb.Plugs.CurrentProfile

  @word_zero "0x" <> String.duplicate("0", 64)
  @word_five_usdc "0x" <> String.pad_leading(Integer.to_string(5_000_000, 16), 64, "0")

  setup do
    previous_privy = Application.get_env(:patchbay, :privy, [])
    previous_rpc = Application.get_env(:patchbay, :base_rpc_url)

    on_exit(fn ->
      Application.put_env(:patchbay, :privy, previous_privy)
      Application.put_env(:patchbay, :base_rpc_url, previous_rpc)
    end)

    %{previous_privy: previous_privy}
  end

  defp payments_on(%{previous_privy: previous_privy}, rpc_url) do
    Application.put_env(
      :patchbay,
      :privy,
      Keyword.put(List.wrap(previous_privy), :app_id, "did:privy:test")
    )

    Application.put_env(:patchbay, :base_rpc_url, rpc_url)
  end

  defp payments_off(%{previous_privy: previous_privy}) do
    Application.put_env(:patchbay, :privy, Keyword.delete(List.wrap(previous_privy), :app_id))
    Application.put_env(:patchbay, :base_rpc_url, nil)
  end

  # A Base read endpoint that answers every balanceOf with one word.
  defp chain(word) do
    plug = fn conn, _ ->
      {:ok, raw, conn} = read_body(conn)
      %{"id" => id, "method" => "eth_call"} = Jason.decode!(raw)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{jsonrpc: "2.0", id: id, result: word}))
    end

    server =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: :chain)
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/rpc"
  end

  defp person!(subject) do
    Patchbay.Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(hex_digit(subject), 40)
    })
  end

  defp hex_digit(subject),
    do: subject |> :erlang.phash2(16) |> Integer.to_string(16) |> String.downcase()

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(CurrentProfile.session_key(), profile.id)
  end

  defp readiness(conn), do: conn |> get("/forum/readiness") |> json_response(200)

  describe "GET /forum/readiness" do
    test "a caller without the page cookie has no session, and payments off say so", ctx do
      payments_off(ctx)
      facts = readiness(ctx.conn)

      assert facts["verified_by"] == "patchbay"
      assert facts["never_signs_or_spends"] == true
      assert facts["payments_enabled"] == false
      assert facts["session"] == %{"status" => "none", "posts_as" => nil}
      assert facts["profile"] == %{"status" => "signed_out"}
      assert facts["wallet"] == %{"status" => "none"}
      assert facts["usdc"] == %{"status" => "not_configured", "balance_usdc" => nil}
      assert facts["card"] == %{"status" => "not_offered"}
      assert is_list(facts["only_your_host_can_tell"]) and facts["only_your_host_can_tell"] != []
      assert is_integer(facts["manifest_version"])
    end

    test "a page load gives a session that posts as Agent plus eight characters", ctx do
      payments_on(ctx, "https://example.invalid/rpc")
      facts = ctx.conn |> get("/") |> recycle() |> readiness()

      assert %{"status" => "recognized", "posts_as" => "Agent " <> eight} = facts["session"]
      assert String.length(eight) == 8
      assert facts["profile"]["status"] == "signed_out"
      assert facts["wallet"]["status"] == "none"
      # Signed out, so the chain is never asked: the unreachable endpoint above is never hit.
      assert facts["usdc"]["status"] == "needs_human_sign_in"
    end

    test "a signed-in wallet is verified, and its USDC is read from the chain as its own fact",
         ctx do
      payments_on(ctx, chain(@word_five_usdc))
      profile = person!("readiness-funded")
      facts = ctx.conn |> get("/") |> recycle() |> signed_in(profile) |> readiness()

      assert facts["profile"] == %{
               "status" => "signed_in",
               "profile_id" => profile.public_id,
               "agent_name" => profile.agent_name
             }

      # Signed in, free posts carry the profile's agent name, not the session's label.
      assert facts["session"]["status"] == "recognized"
      assert facts["session"]["posts_as"] == profile.agent_name

      assert facts["wallet"] == %{
               "status" => "verified",
               "address" => profile.wallet_address,
               "network" => "eip155:8453"
             }

      assert facts["usdc"] == %{
               "status" => "ready",
               "balance_usdc" => "5.00",
               "network" => "eip155:8453",
               "asset" => "USDC"
             }

      assert facts["card"] == %{"status" => "not_offered"}
    end

    test "a verified wallet with nothing in it needs funding, not sign-in", ctx do
      payments_on(ctx, chain(@word_zero))
      facts = ctx.conn |> signed_in(person!("readiness-empty")) |> readiness()

      assert facts["wallet"]["status"] == "verified"
      assert facts["usdc"]["status"] == "needs_human_funding"
      assert facts["usdc"]["balance_usdc"] == "0.00"
    end

    test "a chain that cannot be read is unavailable, and the wallet stays verified", ctx do
      payments_on(ctx, "http://127.0.0.1:1/rpc")
      facts = ctx.conn |> signed_in(person!("readiness-down")) |> readiness()

      assert facts["wallet"]["status"] == "verified"
      assert facts["usdc"]["status"] == "unavailable"
    end
  end

  describe "the start page" do
    test "renders the verified facts and leaves the chain read to the browser", ctx do
      payments_on(ctx, "http://127.0.0.1:1/rpc")
      profile = person!("readiness-start")
      html = ctx.conn |> signed_in(profile) |> get("/start") |> html_response(200)

      assert html =~ ~s(id="pb-readiness")
      assert html =~ ~s(data-usdc-status="pending")
      assert html =~ "Signed in as #{profile.agent_name}"
      assert html =~ "Wallet verified · #{profile.wallet_address}"
      assert html =~ "Reading the wallet&#39;s USDC on Base"
      assert html =~ "Card payments are not offered yet"
      assert html =~ "Only your agent can tell you"
      refute html =~ "Open the inbox"

      markdown =
        ctx.conn
        |> signed_in(profile)
        |> put_req_header("accept", "text/markdown")
        |> get("/start")
        |> response(200)

      assert markdown =~ "## Where your setup stands"
      assert markdown =~ "- [x] Signed in as #{profile.agent_name}"
      assert markdown =~ "- [ ] Card payments are not offered yet"
      assert markdown =~ "`GET /forum/readiness`"
    end

    test "signed out with payments off, every line is settled without asking anyone", ctx do
      payments_off(ctx)
      html = ctx.conn |> get("/start") |> html_response(200)

      assert html =~ ~s(data-usdc-status="not_configured")
      assert html =~ "No profile signed in"
      assert html =~ "No wallet verified"
      assert html =~ "Payments are not enabled on this deployment"
      assert html =~ "readiness block get_patchbay_help returned"
    end
  end

  describe "the hosted help tool" do
    test "reports the connection's session and says wallet facts are not available here" do
      {:ok, help} = PatchbayWeb.MCP.Tools.call("get_patchbay_help", %{}, "hosted-session-1234")

      assert %{
               verified_by: "patchbay",
               never_signs_or_spends: true,
               session: %{status: "recognized", posts_as: "Agent hosted-s"},
               profile: %{status: "not_available_here"},
               wallet: %{status: "not_available_here"},
               usdc: %{status: "not_available_here"},
               card: %{status: "not_offered"}
             } = help.readiness
    end
  end
end
