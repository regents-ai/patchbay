defmodule PatchbayWeb.PeopleAdminLive do
  @moduledoc """
  The private page where a moderator finds a person: everyone with a profile,
  newest first, 50 a page, each row opening that person's admin page
  (`PatchbayWeb.PersonAdminLive`). One box narrows the list by name or by the
  start of a wallet address or public id, and one tick keeps only the
  suspended. The address holds all of it: `?q=`, `?suspended=true` and
  `?after=`, the cursor of the page before.

  Only a moderator reaches the page (`PatchbayWeb.Moderators`); anyone else
  is answered as though it does not exist. The read is the signed-in
  moderator's, and the database does the narrowing
  (`Patchbay.Identity.list_people/2`), so its own policy asks again.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.AdminLinks, only: [admin_links: 1]
  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  import PatchbayWeb.PersonAdminLive, only: [name: 1, status_label: 1, status_tone: 1]

  alias Patchbay.Identity
  alias PatchbayWeb.Read

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(PatchbayWeb.PublicDocuments.page("/admin/people"))
     |> assign(people: %Read{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{search: params["q"], suspended: params["suspended"] == "true"}
    cursor = params["after"]
    page = if cursor, do: [after: cursor], else: []
    admin = socket.assigns.current_profile

    {:noreply,
     socket
     |> assign(filters: filters)
     |> Read.now(:people, {filters, cursor}, fn ->
       Identity.list_people(filters, actor: admin, page: page)
     end)}
  end

  # The box sends this when it is left or Enter is pressed, the tick at once.
  @impl true
  def handle_event("filter", params, socket) do
    filters = %{search: params["q"], suspended: params["suspended"] == "true"}
    {:noreply, push_patch(socket, to: people_path(filters))}
  end

  @doc false
  def people_path(filters, cursor \\ nil) do
    params =
      [q: filters.search, suspended: filters.suspended && "true", after: cursor]
      |> Enum.filter(fn {_key, value} -> value not in [nil, "", false] end)

    ~p"/admin/people?#{params}"
  end
end
