defmodule PatchbayWeb.OpenSkillTest do
  @moduledoc """
  Each address serves a skill of its own (`PatchbayWeb.AgentSkillsController`).
  The open address's names only what answers there: its own addresses, each a
  route the open address has, and the tools ChatGPT's connection lists.
  """

  # It switches ChatGPT's account tools on for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Capabilities
  alias PatchbayWeb.SiteEdition

  @skill_paths ~w(/skill.md /.well-known/skills/patchbay/SKILL.md)

  test "the open address serves its own skill, and patchbay.help the repository's", %{conn: conn} do
    open = File.read!(Application.app_dir(:patchbay, "priv/public/skill_open.md"))
    main = File.read!(Path.expand("../../../skills/patchbay/SKILL.md", __DIR__))

    assert open != main

    for path <- @skill_paths do
      assert conn |> on_open() |> get(path) |> response(200) == open
      assert conn |> get(path) |> response(200) == main
    end

    assert description(conn |> on_open() |> get("/.well-known/skills/index.json")) ==
             front_matter_description(open)

    assert description(get(conn, "/.well-known/skills/index.json")) ==
             front_matter_description(main)
  end

  test "the open address's skill names only addresses and tools that answer there", %{conn: conn} do
    config = Application.fetch_env!(:regent_mcp_agents, :config)
    on_exit(fn -> Application.put_env(:regent_mcp_agents, :config, config) end)

    Application.put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "http://127.0.0.1:1", key: String.duplicate("k", 32)]
    )

    skill = conn |> on_open() |> get("/skill.md") |> response(200)

    # Every address is the open address's own, at a route it answers. The
    # text names the address people reach, whatever host a test runs under.
    addresses =
      ~r{https?://[^\s)`|]*[^\s)`|.,]}
      |> Regex.scan(skill)
      |> Enum.map(fn [address] -> URI.parse(address) end)

    assert addresses != []

    for address <- addresses do
      assert address.host == "open.patchbay.help", URI.to_string(address)
      assert answers_here?(address.path || "/"), URI.to_string(address)
    end

    # Its table lists the tools ChatGPT's connection lists, no more and no fewer.
    served = for tool <- rpc(conn, "tools/list")["result"]["tools"], do: tool["name"]

    listed =
      for [name] <- Regex.scan(~r/^\| `([a-z_]+)` \|/m, skill, capture: :all_but_first), do: name

    assert Enum.sort(listed) == Enum.sort(served)

    # Nowhere does it name a Patchbay tool that connection does not list.
    elsewhere = Enum.map(Capabilities.tools(), & &1.name) -- served
    named = for [name] <- Regex.scan(~r/`([a-z_]+)`/, skill, capture: :all_but_first), do: name

    assert Enum.filter(named, &(&1 in elsewhere)) == []

    refute skill =~ ~r/\bfree\b/i
  end

  # Whether the open address has a route for `path` that is not patchbay.help's
  # alone. A single name reaches the site-page route, which is a site's domain:
  # the skill writes it as HOST.
  defp answers_here?(path) do
    Enum.any?(~w(GET POST), fn verb ->
      case Phoenix.Router.route_info(PatchbayWeb.Router, verb, path, SiteEdition.open_host()) do
        %{route: "/:host"} -> path == "/HOST"
        %{pipe_through: pipelines} -> :main_only not in pipelines
        :error -> false
      end
    end)
  end

  defp description(conn) do
    %{"skills" => [%{"name" => "patchbay", "description" => description}]} =
      json_response(conn, 200)

    description
  end

  defp front_matter_description(skill) do
    [description] = Regex.run(~r/^description: (".*")$/m, skill, capture: :all_but_first)
    Jason.decode!(description)
  end

  defp rpc(conn, method) do
    conn
    |> on_open()
    |> put_req_header("content-type", "application/json")
    |> post("/chatgpt/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: %{}}))
    |> json_response(200)
  end
end
