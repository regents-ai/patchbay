defmodule Patchbay.Forum.SiteCheck do
  @moduledoc """
  Gives a site with WebMCP tools its gallery card, starting from a question
  about it.

  Every new question hands its site here, and two separate steps each run
  at most when they are due:

  - Reading the page. The first question about a site outside the directory
    has its front page read for the WebMCP tools it signs up, and those are
    recorded on the site. This happens once per site, whatever it finds.
  - Taking the picture. A site with at least one tool on record, from its
    page or from agents' reports, and no picture yet has the screenshot
    machine take one. A try that fails, say while that machine is away, is
    tried again by a later question an hour or more on, three tries at most.

  A site joins the gallery once it has both tools and a picture; one without
  tools keeps its board and stays out. Each step is claimed by one UPDATE
  that only a due site matches, so questions arriving together start each
  step once. Sites are handled one at a time, in the order asked about.
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

  @doc "Hands a site to the queue after a question about it. Returns at once."
  @spec check(Ecto.UUID.t()) :: :ok
  def check(site_id), do: GenServer.cast(__MODULE__, {:check, site_id})

  @impl GenServer
  def init(nil), do: {:ok, nil}

  @impl GenServer
  def handle_cast({:check, site_id}, state) do
    run(site_id)
    {:noreply, state}
  end

  @doc "Reads the page and takes the picture, each if due: the work `check/1` queues."
  @spec run(Ecto.UUID.t()) :: term()
  def run(site_id) do
    with [site] <- claim(site_id, :claim_page_check) do
      page_url = page_url(site)
      page_url |> page_tools() |> Enum.each(&record_tool(site, &1))
    end

    with [site] <- claim(site_id, :claim_picture), do: picture(site, page_url(site))
  end

  # One UPDATE that matches only a site the step is due for, so of two
  # checks racing for the same site exactly one gets it back.
  defp claim(site_id, action) do
    %Ash.BulkResult{status: :success, records: records} =
      Site
      |> Ash.Query.filter(id == ^site_id)
      |> Ash.bulk_update!(action, %{},
        authorize?: false,
        strategy: :atomic,
        return_records?: true
      )

    records
  end

  defp page_url(site), do: "https://#{site.origin}/"

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
