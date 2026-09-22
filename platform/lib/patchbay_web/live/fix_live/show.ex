defmodule PatchbayWeb.FixLive.Show do
  @moduledoc """
  One fix as it happens. The page opens on the run the browser asked for,
  or the signed-in person paid for, follows every step Patchbay writes on it
  the moment it is written, and ends with the answer in a form an agent can
  be handed. Nothing on this page changes the run.
  """

  use PatchbayWeb, :live_view

  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias PatchbayWeb.FixLive.Panel

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case find(id, session, socket.assigns.current_profile) do
      {:ok, run} ->
        if connected?(socket), do: Phoenix.PubSub.subscribe(Patchbay.PubSub, Run.topic(run.id))
        {:ok, show(socket, run)}

      :none ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  # The run changed: it is read again as it stands now.
  @impl true
  def handle_info({:assist_run_changed, id}, %{assigns: %{run: %Run{id: id}}} = socket) do
    # The page was granted this run when it opened, so the re-read is
    # Patchbay's own.
    {:ok, run} = Assist.get_run(id, authorize?: false)
    {:noreply, show(socket, run)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp show(socket, run) do
    assign(socket,
      run: run,
      page_title: Panel.headline(run),
      headline: Panel.headline(run),
      working?: Panel.working?(run),
      lines: Panel.lines(run),
      answer: Panel.answer(run, url(~p"/fixes/#{run.id}")),
      host: URI.parse(run.site_url).host
    )
  end

  # The browser's own run, by the identity in its signed cookie; or the
  # signed-in person's, by their profile. Anyone else is sent to the front.
  defp find(id, session, profile) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         nil <- as_browser(uuid, session["forum_session_id"]),
         nil <- as_payer(uuid, profile) do
      :none
    else
      %Run{} = run -> {:ok, run}
      :error -> :none
    end
  end

  defp as_browser(uuid, browser_session_id) when is_binary(browser_session_id) do
    case Assist.get_run_as_browser(uuid, browser_session_id) do
      {:ok, run} -> run
      {:error, _unreadable} -> nil
    end
  end

  defp as_browser(_uuid, _no_session), do: nil

  defp as_payer(_uuid, nil), do: nil

  defp as_payer(uuid, profile) do
    case Assist.get_run(uuid, actor: profile, not_found_error?: false) do
      {:ok, run} -> run
      {:error, _forbidden} -> nil
    end
  end
end
