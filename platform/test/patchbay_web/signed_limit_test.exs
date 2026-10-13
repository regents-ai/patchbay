defmodule PatchbayWeb.SignedLimitTest do
  @moduledoc """
  An address's share of signed agent requests, counted before the sign-in
  service is asked about the signature.
  """

  # It lowers the share for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  setup do
    old = Application.fetch_env!(:patchbay, :signed_per_minute)
    Application.put_env(:patchbay, :signed_per_minute, 3)
    on_exit(fn -> Application.put_env(:patchbay, :signed_per_minute, old) end)

    test = self()

    # The sign-in service, refusing every signature and saying it was asked.
    Req.Test.stub(RegentAgents.Broker, fn conn ->
      send(test, :sign_in_service_asked)

      conn
      |> put_status(401)
      |> Req.Test.json(%{
        error: %{code: "signature_invalid", message: "Not signed", hint: "Sign with SIWA"}
      })
    end)

    :ok
  end

  test "an address's signed requests are counted before the sign-in service is asked, the two that finish a payment too, and one past its share is refused without asking",
       %{conn: conn} do
    payment = Ecto.UUID.generate()
    address = address()

    first = signed(conn, address, "/forum/threads")
    assert first.status == 401
    assert get_resp_header(first, "ratelimit-policy") == [~s("signed";q=3;w=60)]
    assert [~s("signed";r=2;t=) <> _seconds] = get_resp_header(first, "ratelimit")
    assert_received :sign_in_service_asked

    complete = signed(conn, address, "/api/agent/payment_intents/#{payment}/complete")
    refute complete.status == 429
    assert [~s("signed";r=1;t=) <> _seconds] = get_resp_header(complete, "ratelimit")

    execute = signed(conn, address, "/api/agent/payment_intents/#{payment}/execute")
    refute execute.status == 429
    assert [~s("signed";r=0;t=) <> _seconds] = get_resp_header(execute, "ratelimit")

    refused = signed(conn, address, "/forum/threads")
    assert json_response(refused, 429)["error"]["code"] == "too_many_requests"
    assert [~s("signed";r=0;t=) <> _seconds] = get_resp_header(refused, "ratelimit")
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60
    refute_received :sign_in_service_asked

    # Another address has a share of its own.
    assert signed(conn, address(), "/forum/threads").status == 401
  end

  defp signed(conn, address, path) do
    conn
    |> recycle()
    |> Map.put(:remote_ip, address)
    |> put_req_header("x-siwa-signature", "not a signature")
    |> put_req_header("content-type", "application/json")
    |> post(path, "{}")
  end

  # An address nothing else in the suite uses, so its share starts whole.
  defp address,
    do: {0x2001, 0xDB8, :rand.uniform(0xFFFF), :rand.uniform(0xFFFF), 0, 0, 0, 1}
end
