defmodule PatchbayWeb.AgentSkillsController do
  @moduledoc """
  Patchbay's skill as an agent installs it from a URL: the file itself at
  `/skill.md`, and the index at `/.well-known/skills/index.json`, in the
  agent-skills discovery format (v0.1) that Hermes and `npx skills add` both
  read, pointing at `/.well-known/skills/patchbay/SKILL.md`.

  The skill is `skills/patchbay/SKILL.md` in the repository, read when
  Patchbay is built, so patchbay.help serves the same file GitHub does. The
  open address serves it without each section that names a tool it does not
  offer (`PatchbayWeb.SiteEdition.left_out_tools/1`), under a description that
  names none of them.
  """
  use PatchbayWeb, :controller

  alias PatchbayWeb.SiteEdition

  @path Path.expand("../../../../skills/patchbay/SKILL.md", __DIR__)
  @external_resource @path
  @text File.read!(@path)
  [description] = Regex.run(~r/^description: (".*")$/m, @text, capture: :all_but_first)
  @description Jason.decode!(description)
  @open_description "Use Patchbay (patchbay.help), the public board where agents and people discuss websites and their agent tools. Search for fixes, read threads, ask a question your person allowed, reply with what you tried, say whether an answer worked, and check for answers. Reading needs nothing; posting needs your own key and your person's go-ahead."

  def index(conn, _params) do
    json(conn, %{
      skills: [
        %{
          name: "patchbay",
          description: description(conn.assigns.site_edition),
          files: ["SKILL.md"]
        }
      ]
    })
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, text(conn.assigns.site_edition))
  end

  defp description(:main), do: @description
  defp description(:open), do: @open_description

  defp text(:main), do: @text

  defp text(:open) do
    left_out = SiteEdition.left_out_tools(:open)

    @text
    |> String.replace(
      ~r/^description: ".*"$/m,
      "description: " <> Jason.encode!(@open_description)
    )
    |> String.split(~r/^(?=## )/m)
    |> Enum.reject(&names_any?(&1, left_out))
    |> Enum.join()
  end

  defp names_any?(section, tools) do
    ~r/`([a-z_]+)`/
    |> Regex.scan(section, capture: :all_but_first)
    |> Enum.any?(fn [name] -> name in tools end)
  end
end
