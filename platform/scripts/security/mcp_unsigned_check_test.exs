defmodule PatchbayWeb.Security.MCPUnsignedCheckTest do
  @moduledoc """
  Checks that a write tool call to the hosted MCP address (`POST /mcp`) never
  makes the sign-in service work for a caller that did not sign, and that
  every write, signed or not, draws on the address's share of signed requests
  before any signature is checked. Kept out of the regular suite. Run from
  `platform/` with:

      MIX_ENV=test mix test scripts/security/mcp_unsigned_check_test.exs

  The sign-in service is stubbed: it says each time it was asked, and answers
  as the real one does, so the refusal an unsigned write gets can be compared
  with the one it got when the service was asked. The share is set to the
  site's own 120 a minute for the whole site while this runs, so the file runs
  alone (`async: false`).
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  # The sign-in service's answer to a request without signed headers.
  @unsigned_refusal %{
    "error" => %{
      "code" => "http_headers_missing",
      "message" =>
        "missing required signed agent headers: x-siwa-signature, x-siwa-signature-input, " <>
          "x-siwa-receipt, x-key-id, x-timestamp, x-agent-wallet-address, x-agent-chain-id",
      "hint" =>
        "The request's signature headers are missing, too old or malformed. Get the newest client " <>
          "with `curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py`, or if you use regents-cli, " <>
          "run `uv tool upgrade regents-cli`. Then send the request with " <>
          "`uv run siwa_agent.py request METHOD URL` or your regents command, which signs each " <>
          "request fresh, just before sending. Each signature works once, for two minutes."
    }
  }

  setup do
    old = Application.fetch_env!(:patchbay, :signed_per_minute)
    Application.put_env(:patchbay, :signed_per_minute, 120)
    on_exit(fn -> Application.put_env(:patchbay, :signed_per_minute, old) end)

    test = self()

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      send(test, :sign_in_service_asked)
      {:ok, body, conn} = read_body(conn)

      case Jason.decode!(body)["headers"] do
        headers when map_size(headers) == 0 ->
          conn |> put_status(401) |> Req.Test.json(@unsigned_refusal)

        _signed ->
          conn
          |> put_status(401)
          |> Req.Test.json(%{
            error: %{code: "signature_invalid", message: "Not signed", hint: "Sign with SIWA"}
          })
      end
    end)

    :ok
  end

  test "an unsigned write is refused as the sign-in service would refuse it, without asking it",
       %{conn: conn} do
    refused = write(conn, address(), nil)

    assert refused.status == 401,
           "expected 401 for an unsigned write, saw #{refused.status}"

    assert Jason.decode!(refused.resp_body) == @unsigned_refusal,
           "expected the existing refusal, saw #{refused.resp_body}"

    refute_received :sign_in_service_asked,
                    "the sign-in service was asked about a write that carried no signature"
  end

  test "the 121st write in a minute from one address is refused before any sign-in check, signed or not",
       %{conn: conn} do
    address = address()

    # One signed write and 119 unsigned ones spend the address's 120.
    signed = write(conn, address, "not a signature")
    assert signed.status == 401
    assert [policy] = get_resp_header(signed, "ratelimit-policy")
    assert policy =~ ~s("signed";q=120;w=60)
    assert_received :sign_in_service_asked

    for left <- 118..0//-1 do
      unsigned = write(conn, address, nil)
      assert unsigned.status == 401
      assert [budget] = get_resp_header(unsigned, "ratelimit")
      assert budget =~ ~s("signed";r=#{left};t=)
    end

    for signature <- [nil, "not a signature"] do
      over = write(conn, address, signature)

      assert over.status == 429,
             "expected 429 past the share (signature #{inspect(signature)}), saw #{over.status}"

      assert json_response(over, 429)["error"]["code"] == "too_many_requests"
      assert [budget] = get_resp_header(over, "ratelimit")
      assert budget =~ ~s("signed";r=0;t=)
      assert [seconds] = get_resp_header(over, "retry-after")
      assert String.to_integer(seconds) in 1..60
    end

    refute_received :sign_in_service_asked,
                    "the sign-in service was asked about a write past the address's share"

    # Reads stay unsigned and draw nothing from the signed share.
    read = rpc(conn, address, nil, "search_threads", %{"q" => "anything"})
    assert read.status == 200
    refute json_response(read, 200)["result"]["isError"]
    refute Enum.any?(get_resp_header(read, "ratelimit-policy"), &(&1 =~ ~s("signed")))

    # Another address has a share of its own.
    assert write(conn, address(), nil).status == 401
  end

  defp write(conn, address, signature) do
    rpc(conn, address, signature, "ask_question", %{
      "site" => "quiet.example.net",
      "title" => "Anyone home?",
      "body_markdown" => "Testing."
    })
  end

  defp rpc(conn, address, signature, name, arguments) do
    conn = conn |> recycle() |> Map.put(:remote_ip, address)

    conn =
      if signature, do: put_req_header(conn, "x-siwa-signature", signature), else: conn

    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })
    )
  end

  # An address nothing else uses, so its share starts whole.
  defp address,
    do: {0x2001, 0xDB8, :rand.uniform(0xFFFF), :rand.uniform(0xFFFF), 0, 0, 0, 2}
end
