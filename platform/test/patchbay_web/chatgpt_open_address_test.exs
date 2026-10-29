defmodule PatchbayWeb.ChatGPTOpenAddressTest do
  @moduledoc """
  ChatGPT connects at the open address (`PatchbayWeb.SiteEdition`): its sign-in
  names open.patchbay.help as issuer and resource, and everything the plugin's
  tools say or link to sends a person there, never to patchbay.help. The
  plugin names it too, and its website, support, privacy and terms pages
  answer there.
  """

  # It switches OAuth on for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.SiteEdition

  test "the sign-in names the open address as its issuer and resource", %{conn: conn} do
    oauth = Application.fetch_env!(:patchbay, Patchbay.OAuth)
    Application.put_env(:patchbay, Patchbay.OAuth, Keyword.put(oauth, :enabled?, true))
    on_exit(fn -> Application.put_env(:patchbay, Patchbay.OAuth, oauth) end)

    resource =
      conn |> on_open() |> get("/.well-known/oauth-protected-resource") |> json_response(200)

    assert resource["resource"] == "https://open.patchbay.help/chatgpt/mcp"
    assert resource["authorization_servers"] == ["https://open.patchbay.help"]

    server =
      conn |> on_open() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert server["authorization_endpoint"] == "https://open.patchbay.help/oauth/authorize"
  end

  test "the plugin's instructions and help send a person to the open address", %{conn: conn} do
    open = SiteEdition.url(:open)

    instructions = rpc(conn, "initialize", %{})["result"]["instructions"]
    assert instructions =~ "replying happen at #{open}."

    help =
      rpc(conn, "tools/call", %{"name" => "get_patchbay_help", "arguments" => %{}})["result"][
        "structuredContent"
      ]

    assert help["your_identity"] =~ "use #{open}/."
    assert help["not_available_here"] =~ "happen at #{open}."

    assert help["to_post"] == %{
             "webmcp_guide" => open <> "/webmcp",
             "http_reference" => open <> "/openapi.json",
             "ask_in_a_browser" => open <> "/"
           }

    refute Jason.encode!(help) =~ SiteEdition.url(:main)
  end

  test "the repair card opens threads at open.patchbay.help", %{conn: conn} do
    [card] =
      rpc(conn, "resources/read", %{"uri" => "ui://patchbay/repair-card-v2.html"})["result"][
        "contents"
      ]

    assert card["_meta"]["ui"]["domain"] == "https://open.patchbay.help"
    assert card["text"] =~ ~s({url:"https://open.patchbay.help"+thread.url})
    refute card["text"] =~ ~s("https://patchbay.help")
  end

  test "every page the plugin names is at the open address and answers there", %{conn: conn} do
    plugin = "../../../plugins/patchbay" |> Path.expand(__DIR__)

    %{"extensions" => %{"com.openai" => %{"interface" => interface}}} =
      read_json(plugin, "plugin.json")

    %{"mcpServers" => %{"patchbay" => server}} = read_json(plugin, "mcp.json")

    assert server["url"] == "https://open.patchbay.help/chatgpt/mcp"
    assert server["extensions"]["com.openai"]["auth"]["resource"] == RegentOAuth.resource()

    for key <- ~w(websiteURL supportURL privacyPolicyURL termsOfServiceURL) do
      %URI{host: "open.patchbay.help", path: path} = URI.parse(interface[key])
      assert conn |> on_open() |> get(path || "/") |> html_response(200), key
    end
  end

  defp read_json(directory, name),
    do: directory |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp rpc(conn, method, params) do
    conn
    |> on_open()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/chatgpt/mcp",
      Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    )
    |> json_response(200)
  end
end
