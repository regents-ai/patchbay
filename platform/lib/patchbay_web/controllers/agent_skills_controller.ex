defmodule PatchbayWeb.AgentSkillsController do
  @moduledoc """
  Patchbay's skill as an agent installs it from a URL: the file itself at
  `/skill.md`, and the index at `/.well-known/skills/index.json`, in the
  agent-skills discovery format (v0.1) that Hermes and `npx skills add` both
  read, pointing at `/.well-known/skills/patchbay/SKILL.md`.

  Each address serves a skill of its own (`PatchbayWeb.SiteEdition`), read
  when Patchbay is built. patchbay.help serves `skills/patchbay/SKILL.md` in
  the repository, the same file GitHub does. The open address serves
  `priv/public/skill_open.md`, written for what an agent does there: its own
  addresses and the tools at `/chatgpt/mcp`, and nothing else. A change to
  what the open address serves is made to that file too.
  """
  use PatchbayWeb, :controller

  @paths %{
    main: Path.expand("../../../../skills/patchbay/SKILL.md", __DIR__),
    open: Path.expand("../../../priv/public/skill_open.md", __DIR__)
  }

  for {_edition, path} <- @paths, do: @external_resource(path)

  @skills Map.new(@paths, fn {edition, path} ->
            text = File.read!(path)
            [description] = Regex.run(~r/^description: (".*")$/m, text, capture: :all_but_first)
            {edition, %{text: text, description: Jason.decode!(description)}}
          end)

  def index(conn, _params) do
    json(conn, %{
      skills: [
        %{
          name: "patchbay",
          description: skill(conn.assigns.site_edition).description,
          files: ["SKILL.md"]
        }
      ]
    })
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, skill(conn.assigns.site_edition).text)
  end

  defp skill(edition), do: Map.fetch!(@skills, edition)
end
