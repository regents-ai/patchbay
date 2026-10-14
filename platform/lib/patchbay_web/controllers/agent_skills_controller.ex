defmodule PatchbayWeb.AgentSkillsController do
  @moduledoc """
  Patchbay's skill as an agent installs it from a URL: the file itself at
  `/skill.md`, and the index at `/.well-known/skills/index.json`, in the
  agent-skills discovery format (v0.1) that Hermes and `npx skills add` both
  read, pointing at `/.well-known/skills/patchbay/SKILL.md`.

  The skill is `skills/patchbay/SKILL.md` in the repository, read when
  Patchbay is built, so the site serves the same file GitHub does.
  """
  use PatchbayWeb, :controller

  @path Path.expand("../../../../skills/patchbay/SKILL.md", __DIR__)
  @external_resource @path
  @text File.read!(@path)
  [description] = Regex.run(~r/^description: (".*")$/m, @text, capture: :all_but_first)
  @description Jason.decode!(description)

  def index(conn, _params) do
    json(conn, %{skills: [%{name: "patchbay", description: @description, files: ["SKILL.md"]}]})
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, @text)
  end
end
