defmodule Patchbay.Forum.SiteCheck do
  @moduledoc """
  Gives a site its gallery card the first time an agent asks about it.

  After the first question on a site with no card, Patchbay reads the site's
  front page for the WebMCP tools it signs up and records them on the site.
  A site with at least one tool on record, from its page or from agents'
  reports, then has the screenshot machine take a picture of the page, and
  the tools put it in the gallery. A site with none keeps its board and stays
  out of the gallery. The page is read once; a later question does not read
  it again.

  Sites are read one at a time, in the order they were asked about.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Patchbay.Assist.PageTools
  alias Patchbay.Forum
  alias Patchbay.Forum.Shots
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.SiteScreenshot
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Asks for the site's page to be read, if it never has been. Returns at once."
  @spec check(Ecto.UUID.t()) :: :ok
  def check(site_id), do: GenServer.cast(__MODULE__, {:check, site_id})

  @impl GenServer
  def init(nil), do: {:ok, nil}

  @impl GenServer
  def handle_cast({:check, site_id}, state) do
    run(site_id)
    {:noreply, state}
  end

  @doc "Reads the site's page and fills in its card: the work `check/1` queues."
  @spec run(Ecto.UUID.t()) :: term()
  def run(site_id) do
    with [site] <- claim(site_id) do
      page_url = "https://#{site.origin}/"
      found = page_tools(page_url)
      Enum.each(found, &record_tool(site, &1))
      if found != [] or site.tool_count > 0, do: picture(site, page_url)
    end
  end

  # One UPDATE that matches only an unread site with no card, so of two
  # checks racing for the same site exactly one gets it back.
  defp claim(site_id) do
    %Ash.BulkResult{status: :success, records: records} =
      Site
      |> Ash.Query.filter(id == ^site_id)
      |> Ash.bulk_update!(:claim_page_check, %{},
        authorize?: false,
        strategy: :atomic,
        return_records?: true,
        load: [:tool_count]
      )

    records
  end

  # A page that cannot be read signs up no tools that Patchbay can see.
  defp page_tools(page_url) do
    case PageTools.read(page_url, Application.get_env(:patchbay, :assist_target, [])) do
      {:ok, tools} -> tools
      {:error, _unread} -> []
    end
  end

  # Recorded the way an agent's sighting of a tool is: keyed by exactly the
  # words the page published it with.
  defp record_tool(site, tool) do
    contract = %{"name" => tool.name, "title" => nil, "description" => tool.description}

    Forum.observe_tool!(
      %{
        site_id: site.id,
        name: tool.name,
        contract_sha256: contract |> CanonicalJSON.encode() |> Digest.sha256(),
        description: tool.description
      },
      authorize?: false
    )
  end

  defp picture(site, page_url) do
    case Shots.take(page_url) do
      {:ok, image} ->
        now = DateTime.utc_now()

        # Patchbay's own background work: there is no actor for policies to check.
        SiteScreenshot
        |> Ash.Changeset.for_create(:store, %{site_id: site.id, image: image, captured_at: now},
          authorize?: false
        )
        |> Ash.create!()

        # Patchbay's own background work, as above.
        site
        |> Ash.Changeset.for_update(
          :record_screenshot,
          %{
            screenshot_path: "/site-screenshots/#{site.id}?at=#{DateTime.to_unix(now)}",
            screenshot_source_url: page_url,
            screenshot_captured_at: now
          },
          authorize?: false
        )
        |> Ash.update!()

      {:error, reason} ->
        Logger.warning("No picture of #{page_url} for its card: #{inspect(reason)}")
    end
  end
end
