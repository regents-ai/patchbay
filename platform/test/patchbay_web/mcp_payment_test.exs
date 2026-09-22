defmodule PatchbayWeb.MCPPaymentTest do
  @moduledoc "Neither hosted MCP surface can reach payment tools or create payment intents."
  use PatchbayWeb.ConnCase, async: false
  alias Patchbay.Payments.PaymentIntent

  test "payment names are absent and direct invocation cannot create a purchase" do
    before = Ash.count!(PaymentIntent, authorize?: false)

    for path <- ["/mcp", "/mcp/agent"] do
      listed =
        post(build_conn(), path, %{jsonrpc: "2.0", id: 1, method: "tools/list"})
        |> json_response(200)

      names = Enum.map(listed["result"]["tools"], & &1["name"])

      for name <-
            ~w(post_priority_report get_payment_status accept_solution withdraw_priority_report) do
        refute name in names

        result =
          post(build_conn(), path, %{
            jsonrpc: "2.0",
            id: 2,
            method: "tools/call",
            params: %{name: name, arguments: %{}}
          })
          |> json_response(200)

        assert result["error"] || result["result"]["isError"]
      end
    end

    assert Ash.count!(PaymentIntent, authorize?: false) == before
  end
end
