defmodule PatchbayWeb.ChatGPTOpenAddressTest do
  @moduledoc """
  ChatGPT connects at the open address (`PatchbayWeb.SiteEdition`): its sign-in
  names open.patchbay.help as issuer and resource, and everything the plugin's
  tools say or link to sends a person there, never to patchbay.help. The
  plugin names it too: its website, support, privacy and terms pages answer
  there, and its review video plays there.
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
             "http_reference" => open <> "/openapi.json",
             "ask_in_a_browser" => open <> "/"
           }

    refute Jason.encode!(help) =~ SiteEdition.url(:main)
    refute Enum.any?(help["posting_rules"], &(&1 =~ "transaction"))
  end

  test "the site directory links to each site's page at the open address", %{conn: conn} do
    open = SiteEdition.url(:open)

    directory =
      rpc(conn, "tools/call", %{"name" => "read_site_directory", "arguments" => %{}})["result"][
        "structuredContent"
      ]

    assert [_ | _] = directory["sites"]
    for site <- directory["sites"], do: assert(site["url"] == open <> "/" <> site["origin"])
    assert String.starts_with?(directory["pagination"]["next_page_url"], open <> "/sites?")

    page =
      conn
      |> on_open()
      |> put_req_header("accept", "application/json")
      |> get("/sites")
      |> json_response(200)

    assert page["sites"] == directory["sites"]
  end

  test "a GET at the ChatGPT address names no other address", %{conn: conn} do
    refusal = conn |> on_open() |> get("/chatgpt/mcp") |> json_response(405)

    assert refusal["error"] == %{
             "code" => "method_not_allowed",
             "message" => "Send MCP messages to this address with POST.",
             "hint" => "Send the message again with POST."
           }
  end

  test "the not-found answer names the open address's own map", %{conn: conn} do
    open = SiteEdition.url(:open)

    %{"error" => error} = conn |> on_open() |> get("/chatgpt/nothing") |> json_response(404)

    assert error["code"] == "not_found"
    assert error["hint"] =~ "#{open}/openapi.json"
    assert error["hint"] =~ "#{open}/llms.txt"
    refute error["hint"] =~ SiteEdition.url(:main)
  end

  test "the Markdown not-found page maps only pages the open address has", %{conn: conn} do
    page =
      conn
      |> on_open()
      |> put_req_header("accept", "text/markdown")
      |> get("/blog/no-such-post")
      |> response(404)

    links = Regex.scan(~r{\]\((/[^)]*)\)}, page, capture: :all_but_first)

    assert links != []

    for [path] <- links,
        do: refute(conn |> on_open() |> get(path) |> Map.fetch!(:status) == 404, path)
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

  test "the review video is served from the open address to play in the browser", %{conn: conn} do
    %{"extensions" => %{"com.openai" => %{"review" => review}}} =
      "../../../plugins/patchbay" |> Path.expand(__DIR__) |> read_json("plugin.json")

    assert %URI{host: "open.patchbay.help", path: "/videos/" <> _name} =
             URI.parse(review["demo_recording_url"])

    videos = Application.app_dir(:patchbay, "priv/videos")
    name = "check-#{System.unique_integer([:positive])}.mp4"
    File.mkdir_p!(videos)
    File.write!(Path.join(videos, name), "video")
    on_exit(fn -> File.rm!(Path.join(videos, name)) end)

    video = conn |> on_open() |> get("/videos/" <> name)

    assert video.status == 200
    assert get_resp_header(video, "content-type") == ["video/mp4"]

    assert get_resp_header(video, "content-security-policy") == [
             "default-src 'none'; media-src 'self'; frame-ancestors 'none'"
           ]
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
