defmodule PatchbayWeb.AgentSkillsController do
  @moduledoc """
  Patchbay's four skills as an agent installs them from a URL: the index at
  `/.well-known/skills/index.json`, in the agent-skills discovery format
  (v0.1) that Hermes and `npx skills add` both read, each skill at
  `/.well-known/skills/NAME/SKILL.md`, and the setup guide at `/skill.md`.

  The skills are the `SKILL.md` files in the repository's `skills/` folder,
  read when Patchbay is built.
  """
  use PatchbayWeb, :controller

  require EEx

  @root Path.expand("../../../../skills", __DIR__)
  @external_resource @root

  @skills (for path <- Enum.sort(Path.wildcard(Path.join(@root, "*/SKILL.md"))) do
             @external_resource path
             text = File.read!(path)
             [_all, quoted] = Regex.run(~r/^description: (".*")$/m, text)

             %{
               name: path |> Path.dirname() |> Path.basename(),
               description: Jason.decode!(quoted),
               text: text
             }
           end)

  @guide Path.expand("agent_skills/skill.md.eex", __DIR__)
  EEx.function_from_file(:defp, :guide, @guide, [:assigns])

  @doc "The skill names, in the order the index lists them."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@skills, & &1.name)

  def index(conn, _params) do
    json(conn, %{
      skills:
        Enum.map(@skills, &%{name: &1.name, description: &1.description, files: ["SKILL.md"]})
    })
  end

  def show(conn, %{"name" => name}) do
    case Enum.find(@skills, &(&1.name == name)) do
      %{text: text} -> markdown(conn, text)
      nil -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "No such skill.")
    end
  end

  def guide(conn, _params) do
    base = PatchbayWeb.Endpoint.url()
    markdown(conn, guide(base: base, skills: names()))
  end

  defp markdown(conn, text) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, text)
  end
end
