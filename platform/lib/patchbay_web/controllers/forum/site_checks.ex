defmodule PatchbayWeb.Forum.SiteChecks do
  @moduledoc """
  How a site's page asks for its check (`Patchbay.Forum.SiteCheck`): opening
  the page asks when the check is due, and so does "Check again". Every
  check asked for counts against the visitor's share, twenty in ten minutes,
  so one visitor cannot keep Patchbay reading sites for them.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteCheck
  alias PatchbayWeb.ReadLimit

  @window :timer.minutes(10)
  @share 20

  @doc "The site's check as last kept, or nil before the first."
  @spec current(String.t()) :: Ash.Resource.record() | nil
  def current(domain), do: Forum.get_site_check!(domain, not_found_error?: false)

  @doc """
  Asks for a check of `domain` when one is due for `reason` (`:open` or
  `:again`) and the visitor has share left. Answers the check as it now
  stands, and whether this visitor's share was used up.
  """
  @spec ask(String.t(), Ash.Resource.record() | nil, String.t(), :open | :again) ::
          {:ok | :limited, Ash.Resource.record() | nil}
  def ask(domain, check, visitor, reason) do
    with true <- SiteCheck.due?(check, reason),
         {:allow, _count} <- ReadLimit.hit("site-check:" <> visitor, @window, @share) do
      {:ok, Forum.request_site_check!(domain)}
    else
      false -> {:ok, check}
      {:deny, _wait_ms} -> {:limited, check}
    end
  end

  @doc "Where a site's check stands, for the words beside it."
  @spec state(Ash.Resource.record() | nil) :: :none | :checking | :failed | :done
  def state(nil), do: :none

  def state(check) do
    cond do
      SiteCheck.pending?(check) -> :checking
      is_nil(check.findings) -> :failed
      true -> :done
    end
  end

  @doc "Whether a finished check found nothing an agent can use."
  @spec nothing?(map()) :: boolean()
  def nothing?(findings),
    do: Enum.all?(~w(webmcp servers files code), &(findings[&1] == []))

  @doc "What an MCP server said when it was asked for its tools."
  @spec server_label(map()) :: String.t()
  def server_label(%{"sign_in" => true}), do: "Asks for a sign-in first"
  def server_label(%{"answered" => false}), do: "Did not answer just now"
  def server_label(%{"tools" => []}), do: "Lists no tools"
  def server_label(%{"tools" => [_one]}), do: "1 tool"
  def server_label(%{"tools" => tools}), do: "#{length(tools)} tools"

  @doc "The name of a kind of file agents read."
  @spec file_label(String.t()) :: String.t()
  def file_label("llms_txt"), do: "llms.txt"
  def file_label("api_catalog"), do: "API catalog"
  def file_label("openapi"), do: "OpenAPI description"
  def file_label("skills"), do: "Agent skills"
  def file_label("skill_md"), do: "skill.md"
  def file_label("agent_card"), do: "Agent card"

  @doc "The name of a place code and packages are listed."
  @spec source_label(String.t()) :: String.t()
  def source_label("github"), do: "GitHub"
  def source_label("npm"), do: "npm"
  def source_label("pypi"), do: "PyPI"
  def source_label("registry"), do: "MCP Registry"
end
