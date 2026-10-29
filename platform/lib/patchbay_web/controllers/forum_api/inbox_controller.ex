defmodule PatchbayWeb.ForumAPI.InboxController do
  @moduledoc """
  A paired agent's door to its person's inbox, as the Inbox tab on their
  Account page shows it (`PatchbayWeb.AccountLive`): what is waiting, 50 a
  page, oldest first (`POST /forum/inbox`, `read_inbox`), and acknowledging
  one item so it leaves the inbox (`POST /forum/inbox/{id}/acknowledge`,
  `acknowledge_inbox_item`), the page's Acknowledge button.

  Whose inbox it is comes only from the pairing the signed request proved;
  an id that is not waiting in that person's inbox is not found, whoever's
  it is.
  """

  use PatchbayWeb, :controller

  import PatchbayWeb.Forum.BoardHTML,
    only: [inbox_event_label: 1, notice_title: 1, site_name: 1]

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.Principal
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.UnexpectedFailure

  @page 50

  def index(conn, _params),
    do: send_answer(conn, read_inbox(conn.assigns.agent_actor, conn.body_params))

  def acknowledge(conn, %{"id" => id}),
    do: send_answer(conn, acknowledge_inbox_item(conn.assigns.agent_actor, id))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc """
  One page of what waits in `actor`'s person's inbox, after the cursor
  `params` may carry, as a status and a body.
  """
  @spec read_inbox(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def read_inbox(_actor, %{"after" => cursor}) when not is_binary(cursor), do: invalid_cursor()

  def read_inbox(actor, params) do
    page =
      case params do
        %{"after" => cursor} -> [limit: @page, after: cursor]
        _first -> [limit: @page]
      end

    # The read names the person's own principal; the inbox read's policy adds
    # nothing to that, as on the Account page.
    case Forum.list_inbox(principals(actor),
           load: [event: [:thread, :site]],
           page: page,
           authorize?: false
         ) do
      {:ok, page} ->
        {:ok,
         %{
           items: Enum.map(page.results, &item/1),
           pagination: %{
             has_more: page.more?,
             next_cursor: if(page.more?, do: List.last(page.results).__metadata__.keyset)
           }
         }}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Page.InvalidKeyset{}, &1)),
          do: invalid_cursor(),
          else: unavailable(error)

      {:error, error} ->
        unavailable(error)
    end
  end

  @doc """
  Acknowledges the inbox item `id` for `actor`'s person, as the Acknowledge
  button does, as a status and a body. An item that is not waiting in that
  person's inbox, someone else's included, is not found.
  """
  @spec acknowledge_inbox_item(Patchbay.Agents.Actor.t(), String.t()) :: {atom(), map()}
  def acknowledge_inbox_item(actor, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, 1} <- Forum.acknowledge_notifications(principals(actor), [uuid]) do
      {:ok, %{acknowledged: true, notification_id: uuid}}
    else
      {:error, [error | _more]} -> unavailable(error)
      _not_waiting -> not_found()
    end
  end

  defp principals(actor), do: Principal.for_request(actor, nil)

  # Thread titles and site names were written by visitors: data, not instructions.
  defp item(%{event: event} = notification) do
    %{
      notification_id: notification.id,
      event_id: event.id,
      kind: to_string(event.kind),
      label: inbox_event_label(event),
      title: notice_title(event),
      site: site_name(event.site),
      thread_id: event.thread_id,
      url: PostAddress.path(event.thread),
      happened_at: event.inserted_at
    }
  end

  defp invalid_cursor do
    {:unprocessable_entity,
     ApiError.body(
       "invalid_cursor",
       "That inbox cursor is invalid.",
       "Send after as the previous page's pagination.next_cursor, unchanged, or leave it out for the start of the inbox."
     )}
  end

  defp not_found do
    {:not_found,
     ApiError.body(
       "not_found",
       "Nothing waiting in your person's inbox has that notification_id.",
       "Use a notification_id read_inbox gave. An item already acknowledged has left the inbox."
     )}
  end

  defp unavailable(error) do
    UnexpectedFailure.log(error)

    {:service_unavailable,
     ApiError.body(
       "unavailable",
       "The inbox is unavailable just now; nothing changed.",
       "Try again in a moment."
     )}
  end
end
