defmodule PatchbayWeb.AdminMessagesLive do
  @moduledoc """
  The private page where Patchbay's team reads the messages people and their
  agents left for it (`Patchbay.Messages`), newest first, 50 a page. `?after=`
  holds the cursor of the page before.

  Only a moderator reaches the page (`PatchbayWeb.Moderators`); anyone else
  is answered as though it does not exist. The read is the signed-in
  moderator's, so its own policy asks again.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.Messages
  alias PatchbayWeb.Read

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(PatchbayWeb.PublicDocuments.page("/admin/messages"))
     |> assign(messages: %Read{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    cursor = params["after"]
    page = if cursor, do: [after: cursor], else: []
    admin = socket.assigns.current_profile

    {:noreply,
     Read.now(socket, :messages, cursor, fn ->
       Messages.list_messages(actor: admin, page: page)
     end)}
  end
end
